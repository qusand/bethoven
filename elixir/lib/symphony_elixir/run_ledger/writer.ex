defmodule SymphonyElixir.RunLedger.WriterSupervisor do
  @moduledoc false

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule SymphonyElixir.RunLedger.Writer do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.RunLedger

  @legacy_schema_version 3

  @spec child_spec(Path.t()) :: Supervisor.child_spec()
  def child_spec(path) when is_binary(path) do
    %{
      id: {__MODULE__, path},
      start: {__MODULE__, :start_link, [path]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(path) when is_binary(path) do
    GenServer.start_link(__MODULE__, path, name: {:via, Registry, {RunLedger.writer_registry_name(), path}})
  end

  @impl true
  def init(path) do
    with {:ok, storage} <- RunLedger.open_storage(path),
         {:ok, table} <- open_table(path),
         :ok <- RunLedger.finalize_storage(storage),
         # DETS may replace its file while repairing during open. Bind only
         # after that completes; any later pathname identity change is unsafe
         # because the open table can still write through the old handle.
         {:ok, storage} <- RunLedger.bind_storage_leaf(storage),
         {:ok, issues, intents} <- rebuild(table),
         {:ok, issues} <- auto_recover_intents(table, issues, intents) do
      state = %{
        path: path,
        storage: storage,
        storage_error: nil,
        table: table,
        issues: issues,
        intents: %{},
        health: :healthy
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:ledger_open_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    _ = :dets.sync(table)
    _ = :dets.close(table)
    :ok
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    case storage_state(state) do
      {:ok, state} ->
        reply =
          if state.health == :healthy do
            {:ok, %{issues: state.issues}}
          else
            {:error, {:ledger_recovery_required, health_ids(state.health)}}
          end

        {:reply, reply, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:issue, issue_id}, _from, state) do
    case storage_state(state) do
      {:ok, state} ->
        reply =
          if state.health == :healthy do
            {:ok, Map.get(state.issues, issue_id)}
          else
            {:error, {:ledger_recovery_required, health_ids(state.health)}}
          end

        {:reply, reply, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:health, _from, state) do
    case storage_state(state) do
      {:ok, state} -> {:reply, {:ok, state.health}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append, event, opts}, _from, state) do
    case storage_state(state) do
      {:ok, %{health: :healthy} = state} ->
        case append_event(state, event, opts) do
          {:ok, updated_state} ->
            {:reply, {:ok, %{issues: updated_state.issues}}, updated_state}

          {:error, reason, updated_state} ->
            {:reply, {:error, reason}, updated_state}
        end

      {:ok, state} ->
        {:reply, {:error, {:ledger_recovery_required, health_ids(state.health)}}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recover, event, _opts}, _from, state) do
    case storage_state(state) do
      {:ok, state} ->
        recover_call_reply(state, event)

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp recover_call_reply(state, event) do
    event_id = event["event_id"]

    case Map.get(state.intents, event_id) do
      nil ->
        {:reply, {:error, {:no_recovery_intent, event_id}}, state}

      %{"identity" => identity} = intent ->
        recover_intent_reply(state, event, event_id, identity, intent)
    end
  end

  defp recover_intent_reply(state, event, event_id, identity, intent) do
    if identity == event["identity"] do
      recovery_result_reply(recover_intent(state, event_id, intent))
    else
      {:reply, {:error, {:duplicate_event_conflict, event_id}}, state}
    end
  end

  defp recovery_result_reply({:ok, updated_state}) do
    {:reply, {:ok, %{issues: updated_state.issues}}, updated_state}
  end

  defp recovery_result_reply({:error, reason, updated_state}) do
    {:reply, {:error, reason}, updated_state}
  end

  defp open_table(path) do
    case :dets.open_file(make_ref(), file: String.to_charlist(path), type: :set, repair: true) do
      {:ok, table} -> {:ok, table}
      {:error, reason} -> {:error, {:dets_open_failed, reason}}
    end
  end

  defp append_event(state, event, opts) do
    event_id = event["event_id"]

    case lookup_event_identity(state.table, event_id) do
      {:ok, identity_record} ->
        duplicate_or_conflict(state, identity_record, event)

      :missing ->
        issue =
          Map.get(
            state.issues,
            event["issue_id"],
            RunLedger.empty_issue(event["issue_id"], event["issue_identifier"])
          )

        case RunLedger.apply_event(issue, event, opts.max_events_per_issue) do
          {:ok, projection} ->
            intent = recovery_intent(event, issue, projection, opts.max_events_per_issue)
            append_with_intent(state, event_id, intent, opts)

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, {:ledger_corrupt, reason}, latch_unhealthy(state)}
    end
  end

  defp append_with_intent(state, event_id, intent, opts) do
    case write_intent(state.table, event_id, intent) do
      :ok ->
        commit_intended_event(state, event_id, intent, opts)

      {:error, _reason} ->
        {:error, {:commit_unknown, event_id}, latch_recovery(state, event_id, intent)}
    end
  end

  defp commit_intended_event(state, event_id, intent, opts) do
    event = intent["event"]

    with :ok <- run_fault(opts, :before_commit),
         :ok <- write_checkpoint(state.table, event["issue_id"], intent["projection"], intent["retention"]),
         :ok <- run_fault(opts, :after_checkpoint),
         :ok <- write_event_identity(state.table, event_id, intent["identity"]),
         :ok <- run_fault(opts, :after_commit),
         :ok <- run_fault(opts, :before_clear_intent),
         :ok <- clear_intent(state.table, event_id),
         :ok <- run_fault(opts, :after_clear_intent) do
      {:ok, %{state | issues: Map.put(state.issues, event["issue_id"], intent["projection"])}}
    else
      {:error, _reason} ->
        # Every post-intent failure is ambiguous at the caller boundary. The
        # durable intent contains the base and target projections required to
        # finish exactly once after a restart.
        {:error, {:commit_unknown, event_id}, latch_recovery(state, event_id, intent)}
    end
  end

  defp duplicate_or_conflict(state, %{"identity" => persisted_identity}, event) do
    if persisted_identity == event["identity"] do
      {:ok, state}
    else
      {:error, {:duplicate_event_conflict, event["event_id"]}, state}
    end
  end

  defp duplicate_or_conflict(state, _identity_record, event) do
    {:error, {:ledger_corrupt, {:invalid_event_identity, event["event_id"]}}, latch_unhealthy(state)}
  end

  defp recover_intent(state, event_id, intent) do
    event = intent["event"]

    issue =
      Map.get(
        state.issues,
        event["issue_id"],
        RunLedger.empty_issue(event["issue_id"], event["issue_identifier"])
      )

    case lookup_event_identity(state.table, event_id) do
      {:ok, %{"identity" => persisted_identity}} ->
        if persisted_identity == intent["identity"] and checkpoint_matches_intent?(issue, intent) do
          clear_recovered_intent(state, event_id)
        else
          {:error, {:ledger_recovery_required, event_id}, latch_recovery(state, event_id, intent)}
        end

      :missing ->
        recover_without_identity(state, event_id, intent, issue)

      {:error, reason} ->
        {:error, {:ledger_corrupt, reason}, latch_unhealthy(state)}
    end
  end

  defp recover_without_identity(state, event_id, intent, issue) do
    event = intent["event"]

    cond do
      checkpoint_matches_intent?(issue, intent) ->
        with :ok <- write_event_identity(state.table, event_id, intent["identity"]),
             :ok <- clear_intent(state.table, event_id) do
          {:ok, clear_recovery_intent(state, event_id)}
        else
          {:error, reason} ->
            {:error, reason, latch_recovery(state, event_id, intent)}
        end

      checkpoint_matches_base?(issue, intent) ->
        with {:ok, projection} <- RunLedger.apply_event(issue, event, intent["retention"]),
             true <- projection == intent["projection"],
             :ok <- write_checkpoint(state.table, event["issue_id"], projection, intent["retention"]),
             :ok <- write_event_identity(state.table, event_id, intent["identity"]),
             :ok <- clear_intent(state.table, event_id) do
          updated_state = %{state | issues: Map.put(state.issues, event["issue_id"], projection)}
          {:ok, clear_recovery_intent(updated_state, event_id)}
        else
          false ->
            {:error, {:ledger_recovery_required, event_id}, latch_recovery(state, event_id, intent)}

          {:error, reason} ->
            {:error, reason, latch_recovery(state, event_id, intent)}
        end

      true ->
        {:error, {:ledger_recovery_required, event_id}, latch_recovery(state, event_id, intent)}
    end
  end

  defp clear_recovered_intent(state, event_id) do
    case clear_intent(state.table, event_id) do
      :ok -> {:ok, clear_recovery_intent(state, event_id)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp recovery_intent(event, issue, projection, retention) do
    %{
      "schema_version" => RunLedger.schema_version(),
      "identity" => event["identity"],
      "event" => event,
      "base_version" => issue.version,
      "base_last_event_id" => issue.last_event_id,
      "projection" => projection,
      "retention" => retention
    }
  end

  defp write_intent(table, event_id, intent) do
    with :ok <- dets_insert(table, {{:intent, event_id}, intent}),
         :ok <- dets_sync(table) do
      :ok
    else
      {:error, reason} -> {:error, {:ledger_intent_failed, reason}}
    end
  end

  defp write_checkpoint(table, issue_id, projection, retention) do
    checkpoint = %{
      "schema_version" => RunLedger.schema_version(),
      "projection" => projection,
      "retention" => retention
    }

    with :ok <- dets_insert(table, {{:checkpoint, issue_id}, checkpoint}),
         :ok <- dets_sync(table) do
      :ok
    else
      {:error, reason} -> {:error, {:checkpoint_write_failed, reason}}
    end
  end

  defp write_event_identity(table, event_id, identity) do
    identity_record = %{
      "schema_version" => RunLedger.schema_version(),
      "identity" => identity
    }

    with :ok <- dets_insert(table, {{:event, event_id}, identity_record}),
         :ok <- dets_sync(table) do
      :ok
    else
      {:error, reason} -> {:error, {:event_identity_write_failed, reason}}
    end
  end

  defp clear_intent(table, event_id) do
    with :ok <- dets_delete(table, {:intent, event_id}),
         :ok <- dets_sync(table) do
      :ok
    else
      {:error, reason} -> {:error, {:intent_clear_failed, reason}}
    end
  end

  defp run_fault(%{fault_injector: nil}, _phase), do: :ok

  defp run_fault(%{fault_injector: fault_injector}, phase) when is_function(fault_injector, 1) do
    case fault_injector.(phase) do
      :ok -> :ok
      nil -> :ok
      {:error, reason} -> {:error, {:fault_injected, phase, reason}}
      other -> {:error, {:fault_injected, phase, other}}
    end
  end

  defp lookup_event_identity(table, event_id) do
    case :dets.lookup(table, {:event, event_id}) do
      [{{:event, ^event_id}, identity_record}] ->
        case RunLedger.validate_persisted_event_identity(identity_record, event_id) do
          {:ok, valid_identity_record} -> {:ok, valid_identity_record}
          {:error, reason} -> {:error, {:invalid_persisted_event_identity, reason}}
        end

      [] ->
        :missing

      _ ->
        {:error, :invalid_dets_record}
    end
  end

  defp rebuild(table) do
    result =
      :dets.foldl(
        fn
          {{:checkpoint, issue_id}, checkpoint}, {:ok, checkpoints, intents} when is_binary(issue_id) ->
            case RunLedger.validate_persisted_checkpoint(checkpoint, issue_id) do
              {:ok, valid_checkpoint} ->
                {:ok, Map.put(checkpoints, issue_id, valid_checkpoint), intents}

              {:error, reason} ->
                {:error, {:invalid_persisted_checkpoint, reason}}
            end

          {{:event, _event_id}, %{"schema_version" => @legacy_schema_version}}, _acc ->
            {:error, {:ledger_migration_required, @legacy_schema_version, RunLedger.schema_version()}}

          {{:event, event_id}, identity_record}, {:ok, checkpoints, intents} when is_binary(event_id) ->
            case RunLedger.validate_persisted_event_identity(identity_record, event_id) do
              {:ok, _valid_identity_record} -> {:ok, checkpoints, intents}
              {:error, reason} -> {:error, {:invalid_persisted_commit, reason}}
            end

          {{:intent, _event_id}, %{"schema_version" => @legacy_schema_version}}, _acc ->
            {:error, {:ledger_migration_required, @legacy_schema_version, RunLedger.schema_version()}}

          {{:intent, event_id}, intent}, {:ok, checkpoints, intents}
          when is_binary(event_id) and is_map(intent) ->
            case RunLedger.validate_persisted_intent(intent, event_id) do
              {:ok, valid_intent} -> {:ok, checkpoints, Map.put(intents, event_id, valid_intent)}
              {:error, reason} -> {:error, {:invalid_persisted_intent, reason}}
            end

          _record, _acc ->
            {:error, :invalid_dets_record}
        end,
        {:ok, %{}, %{}},
        table
      )

    with {:ok, checkpoints, intents} <- result,
         :ok <- validate_checkpoint_identities(table, checkpoints, intents) do
      issues = Map.new(checkpoints, fn {issue_id, checkpoint} -> {issue_id, checkpoint["projection"]} end)
      {:ok, issues, intents}
    else
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:dets_fold_failed, reason}}
  end

  defp validate_checkpoint_identities(table, checkpoints, intents) do
    Enum.reduce_while(checkpoints, :ok, fn {issue_id, checkpoint}, :ok ->
      continue_checkpoint_validation(validate_checkpoint_identity(table, issue_id, checkpoint, intents))
    end)
  end

  defp validate_checkpoint_identity(table, issue_id, checkpoint, intents) do
    projection = checkpoint["projection"]
    event_id = projection.last_event_id

    case lookup_event_identity(table, event_id) do
      {:ok, %{"identity" => identity}} ->
        validate_checkpoint_event_identity(identity, issue_id)

      :missing ->
        validate_checkpoint_intent(issue_id, projection, event_id, intents)

      {:error, reason} ->
        {:error, {:invalid_persisted_commit, reason}}
    end
  end

  defp continue_checkpoint_validation(:ok), do: {:cont, :ok}
  defp continue_checkpoint_validation({:error, reason}), do: {:halt, {:error, reason}}

  defp validate_checkpoint_event_identity(%{"issue_id" => identity_issue_id}, issue_id)
       when identity_issue_id == issue_id,
       do: :ok

  defp validate_checkpoint_event_identity(_identity, _issue_id) do
    {:error, {:invalid_persisted_checkpoint, :event_identity_issue_mismatch}}
  end

  defp validate_checkpoint_intent(issue_id, projection, event_id, intents) do
    case Map.get(intents, event_id) do
      %{} = intent -> validate_checkpoint_intent_projection(issue_id, projection, intent)
      _ -> {:error, {:invalid_persisted_checkpoint, :missing_event_identity}}
    end
  end

  defp validate_checkpoint_intent_projection(issue_id, projection, intent) do
    if intent["event"]["issue_id"] == issue_id and checkpoint_matches_intent?(projection, intent) do
      :ok
    else
      {:error, {:invalid_persisted_checkpoint, :intent_projection_mismatch}}
    end
  end

  defp auto_recover_intents(_table, issues, intents) when map_size(intents) == 0, do: {:ok, issues}

  defp auto_recover_intents(table, issues, intents) do
    intents
    |> Enum.sort_by(fn {event_id, intent} ->
      {intent["event"]["issue_id"], intent["base_version"], event_id}
    end)
    |> Enum.reduce_while({:ok, issues}, fn {event_id, intent}, {:ok, issues_acc} ->
      case auto_recover_intent(table, issues_acc, event_id, intent) do
        {:ok, recovered_issues} -> {:cont, {:ok, recovered_issues}}
        {:error, reason} -> {:halt, {:error, {:ledger_recovery_required, event_id, reason}}}
      end
    end)
  end

  defp auto_recover_intent(table, issues, event_id, intent) do
    event = intent["event"]

    issue =
      Map.get(
        issues,
        event["issue_id"],
        RunLedger.empty_issue(event["issue_id"], event["issue_identifier"])
      )

    case lookup_event_identity(table, event_id) do
      {:ok, %{"identity" => identity}} ->
        auto_recover_committed_intent(table, issues, event_id, intent, issue, identity)

      :missing ->
        auto_recover_missing_intent(table, issues, event_id, intent, event, issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auto_recover_committed_intent(table, issues, event_id, intent, issue, identity) do
    if identity == intent["identity"] and checkpoint_matches_intent?(issue, intent) do
      clear_auto_recovered_intent(table, issues, event_id)
    else
      {:error, :intent_identity_or_checkpoint_mismatch}
    end
  end

  defp clear_auto_recovered_intent(table, issues, event_id) do
    case clear_intent(table, event_id) do
      :ok -> {:ok, issues}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auto_recover_missing_intent(table, issues, event_id, intent, event, issue) do
    cond do
      checkpoint_matches_intent?(issue, intent) ->
        recover_checkpoint_only_intent(table, issues, event_id, intent)

      checkpoint_matches_base?(issue, intent) ->
        recover_base_checkpoint_intent(table, issues, event_id, intent, event, issue)

      true ->
        {:error, :unexpected_checkpoint_for_intent}
    end
  end

  defp recover_checkpoint_only_intent(table, issues, event_id, intent) do
    with :ok <- write_event_identity(table, event_id, intent["identity"]),
         :ok <- clear_intent(table, event_id) do
      {:ok, issues}
    end
  end

  defp recover_base_checkpoint_intent(table, issues, event_id, intent, event, issue) do
    with {:ok, projection} <- RunLedger.apply_event(issue, event, intent["retention"]),
         true <- projection == intent["projection"],
         :ok <- write_checkpoint(table, event["issue_id"], projection, intent["retention"]),
         :ok <- write_event_identity(table, event_id, intent["identity"]),
         :ok <- clear_intent(table, event_id) do
      {:ok, Map.put(issues, event["issue_id"], projection)}
    else
      false -> {:error, :intent_projection_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkpoint_matches_intent?(issue, intent), do: issue == intent["projection"]

  defp checkpoint_matches_base?(issue, intent) do
    issue.version == intent["base_version"] and
      issue.last_event_id == intent["base_last_event_id"] and
      (issue.version > 0 or issue.status == "unknown")
  end

  defp dets_insert(table, object) do
    case :dets.insert(table, object) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dets_delete(table, key) do
    case :dets.delete(table, key) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dets_sync(table) do
    case :dets.sync(table) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp latch_unhealthy(state) do
    %{state | health: {:recovery_required, Map.keys(state.intents) |> Enum.sort()}}
  end

  defp latch_recovery(state, event_id, intent) do
    intents = Map.put(state.intents, event_id, intent)
    %{state | intents: intents, health: {:recovery_required, Map.keys(intents) |> Enum.sort()}}
  end

  defp clear_recovery_intent(state, event_id) do
    intents = Map.delete(state.intents, event_id)

    %{
      state
      | intents: intents,
        health: if(map_size(intents) == 0, do: :healthy, else: {:recovery_required, Map.keys(intents) |> Enum.sort()})
    }
  end

  defp storage_state(%{storage_error: reason} = state) when not is_nil(reason),
    do: {:error, reason, state}

  defp storage_state(%{storage: storage} = state) do
    case RunLedger.validate_storage(storage) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, %{state | storage_error: reason}}
    end
  end

  defp health_ids({:recovery_required, event_ids}), do: event_ids
end
