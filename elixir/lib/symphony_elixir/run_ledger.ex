defmodule SymphonyElixir.RunLedger do
  @moduledoc """
  Durable, single-writer issue-run ledger.

  The schema-v4 layout stores one current checkpoint per issue, an immutable
  canonical identity for every accepted event, and temporary recovery intents
  around checkpoint writes. Exact event IDs are retained for the lifetime of
  the ledger; only the per-issue display history is bounded. Any uncertain
  commit boundary fails closed until the exact event is recovered.
  """

  alias SymphonyElixir.{
    PathSafety,
    RunLedger.Projection,
    RunLedger.Storage,
    RunLedger.Writer,
    RunLedger.WriterSupervisor
  }

  @type issue_snapshot :: %{
          required(:issue_id) => String.t(),
          required(:status) => String.t(),
          required(:session_count) => non_neg_integer(),
          required(:turn_count) => non_neg_integer(),
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer(),
          required(:consecutive_failures) => non_neg_integer(),
          optional(atom()) => term()
        }

  @type snapshot :: %{issues: %{optional(String.t()) => issue_snapshot()}}

  @state_root_binding_schema_version 1
  @workflow_anchor_directory "bindings"
  @state_root_marker_filename ".symphony-workflow-binding.json"
  @binding_fault_stages [
    :root_marker_prepared,
    :root_marker_published,
    :root_marker_written,
    :anchor_marker_prepared,
    :anchor_marker_published,
    :anchor_marker_written
  ]
  @binding_pending_suffix ".pending-v1"

  @doc """
  Returns the local DETS path for a configured local state root.
  """
  @spec default_path(Path.t()) :: Path.t()
  def default_path(state_root) when is_binary(state_root) do
    Path.join([Path.expand(state_root), "issue-runs.dets"])
  end

  @doc """
  Derives a stable local state namespace from the canonical workflow identity.
  """
  @spec default_state_root(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def default_state_root(workflow_path) when is_binary(workflow_path) do
    case PathSafety.canonicalize(workflow_path) do
      {:ok, canonical_workflow_path} ->
        namespace =
          canonical_workflow_path
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)

        {:ok, Path.join([System.user_home!(), ".symphony", "state", "workflow-#{namespace}"])}

      {:error, reason} ->
        {:error, {:invalid_workflow_identity, reason}}
    end
  end

  @doc false
  @spec bind_state_root(Path.t(), Path.t()) :: :ok | {:error, term()}
  def bind_state_root(workflow_path, configured_root)
      when is_binary(workflow_path) and is_binary(configured_root) do
    bind_state_root(workflow_path, configured_root, [])
  end

  @doc false
  @spec bind_state_root(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def bind_state_root(workflow_path, configured_root, opts)
      when is_binary(workflow_path) and is_binary(configured_root) and is_list(opts) do
    with {:ok, canonical_workflow_path} <- PathSafety.canonicalize(workflow_path),
         {:ok, canonical_root} <- PathSafety.canonical_local_path(configured_root),
         {:ok, anchor_path} <- workflow_anchor_path(canonical_workflow_path, opts),
         {:ok, anchor_binding} <- prepare_binding_marker(anchor_path),
         {:ok, anchor_status} <- read_binding_marker(anchor_binding.path),
         :ok <- validate_existing_anchor(anchor_status, canonical_workflow_path, canonical_root),
         {:ok, root_binding} <- prepare_binding_marker(Path.join(canonical_root, @state_root_marker_filename)),
         :ok <- validate_root_identity_for_anchor(anchor_status, root_binding),
         {:ok, root_status} <-
           validate_existing_root_marker(
             root_binding.path,
             canonical_workflow_path,
             root_binding.root_identity,
             anchor_status
           ),
         :ok <-
           write_missing_root_marker(
             anchor_status,
             root_status,
             root_binding,
             canonical_workflow_path,
             opts
           ),
         :ok <- binding_checkpoint(opts, :root_marker_written),
         :ok <-
           write_missing_anchor(
             anchor_status,
             anchor_binding,
             canonical_workflow_path,
             canonical_root,
             root_binding.root_identity,
             opts
           ),
         :ok <- binding_checkpoint(opts, :anchor_marker_written) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  def bind_state_root(_workflow_path, _configured_root, _opts), do: {:error, :invalid_state_root_binding_options}

  @spec load(Path.t()) :: {:ok, snapshot()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, canonical_path} <- canonical_path(path),
         {:ok, writer} <- writer_for(canonical_path) do
      writer_call(writer, :snapshot)
    end
  end

  @spec issue(Path.t(), String.t()) :: {:ok, issue_snapshot() | nil} | {:error, term()}
  def issue(path, issue_id) when is_binary(path) and is_binary(issue_id) do
    with {:ok, canonical_path} <- canonical_path(path),
         {:ok, writer} <- writer_for(canonical_path) do
      writer_call(writer, {:issue, issue_id})
    end
  end

  @spec append(Path.t(), map(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def append(path, event, opts \\ []) when is_binary(path) and is_map(event) and is_list(opts) do
    with {:ok, normalized_event, normalized_opts} <- normalize_event(event, opts),
         {:ok, canonical_path} <- canonical_path(path),
         {:ok, writer} <- writer_for(canonical_path) do
      writer_call(writer, {:append, normalized_event, normalized_opts})
    end
  end

  @doc """
  Explicitly resolves a sync-unknown commit using the same canonical event ID
  and payload that created the durable intent.
  """
  @spec recover(Path.t(), map(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def recover(path, event, opts \\ []) when is_binary(path) and is_map(event) and is_list(opts) do
    with {:ok, normalized_event, normalized_opts} <- normalize_event(event, opts),
         {:ok, canonical_path} <- canonical_path(path),
         {:ok, writer} <- writer_for(canonical_path) do
      writer_call(writer, {:recover, normalized_event, normalized_opts})
    end
  end

  @spec health(Path.t()) :: {:ok, :healthy | {:recovery_required, [String.t()]}} | {:error, term()}
  def health(path) when is_binary(path) do
    with {:ok, canonical_path} <- canonical_path(path),
         {:ok, writer} <- writer_for(canonical_path) do
      writer_call(writer, :health)
    end
  end

  @doc false
  @spec close(Path.t()) :: :ok | {:error, term()}
  def close(path) when is_binary(path) do
    with {:ok, canonical_path} <- canonical_path(path) do
      try do
        case Registry.lookup(SymphonyElixir.RunLedger.Registry, canonical_path) do
          [{pid, _value}] ->
            DynamicSupervisor.terminate_child(WriterSupervisor, pid)

          [] ->
            :ok
        end
      rescue
        ArgumentError -> {:error, {:ledger_writer_unavailable, :registry_unavailable}}
      catch
        :exit, reason -> {:error, {:ledger_writer_unavailable, reason}}
      end
    end
  end

  @doc false
  @spec schema_version() :: pos_integer()
  def schema_version, do: Projection.schema_version()

  @doc false
  @spec normalize_event(map(), keyword()) :: {:ok, map(), map()} | {:error, term()}
  def normalize_event(event, opts) when is_map(event) and is_list(opts) do
    Projection.normalize_event(event, opts)
  end

  @doc false
  @spec validate_persisted_commit(term()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_commit(commit), do: Projection.validate_persisted_commit(commit)

  @doc false
  @spec validate_persisted_intent(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_intent(intent, event_id), do: Projection.validate_persisted_intent(intent, event_id)

  @doc false
  @spec validate_persisted_checkpoint(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_checkpoint(checkpoint, issue_id),
    do: Projection.validate_persisted_checkpoint(checkpoint, issue_id)

  @doc false
  @spec validate_persisted_event_identity(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_event_identity(record, event_id),
    do: Projection.validate_persisted_event_identity(record, event_id)

  @doc false
  @spec empty_issue(String.t(), String.t() | nil) :: issue_snapshot()
  def empty_issue(issue_id, issue_identifier) when is_binary(issue_id) do
    Projection.empty_issue(issue_id, issue_identifier)
  end

  @doc false
  @spec apply_event(issue_snapshot(), map(), pos_integer()) :: {:ok, issue_snapshot()} | {:error, term()}
  def apply_event(issue, event, retention)
      when is_map(issue) and is_map(event) and is_integer(retention) and retention > 0 do
    Projection.apply_event(issue, event, retention)
  end

  @doc false
  @spec ensure_storage_path(Path.t()) :: :ok | {:error, term()}
  def ensure_storage_path(path) when is_binary(path) do
    case open_storage(path) do
      {:ok, _binding} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec open_storage(Path.t()) :: {:ok, Storage.binding()} | {:error, term()}
  def open_storage(path) when is_binary(path) do
    case Storage.prepare(path) do
      {:ok, binding} -> {:ok, binding}
      {:error, reason} -> {:error, {:unsafe_ledger_path, reason}}
    end
  end

  @doc false
  @spec finalize_storage(Storage.binding()) :: :ok | {:error, term()}
  def finalize_storage(binding) do
    case Storage.finalize(binding) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_ledger_path, reason}}
    end
  end

  @doc false
  @spec bind_storage_leaf(Storage.binding()) :: {:ok, Storage.binding()} | {:error, term()}
  def bind_storage_leaf(binding) do
    case Storage.bind_ledger_leaf(binding) do
      {:ok, bound_storage} -> {:ok, bound_storage}
      {:error, reason} -> {:error, {:unsafe_ledger_path, reason}}
    end
  end

  @doc false
  @spec validate_storage(Storage.binding()) :: :ok | {:error, term()}
  def validate_storage(binding) do
    case Storage.validate(binding) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_ledger_path, reason}}
    end
  end

  @doc false
  @spec writer_registry_name() :: atom()
  def writer_registry_name, do: SymphonyElixir.RunLedger.Registry

  defp writer_for(canonical_path) do
    case Registry.lookup(SymphonyElixir.RunLedger.Registry, canonical_path) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(WriterSupervisor, {Writer, canonical_path}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} when is_pid(pid) -> {:ok, pid}
          {:error, reason} -> {:error, {:ledger_writer_unavailable, reason}}
        end
    end
  rescue
    ArgumentError -> {:error, {:ledger_writer_unavailable, :registry_unavailable}}
  catch
    :exit, reason -> {:error, {:ledger_writer_unavailable, reason}}
  end

  defp writer_call(writer, message) do
    GenServer.call(writer, message, 30_000)
  catch
    :exit, reason -> {:error, {:ledger_writer_unavailable, reason}}
  end

  defp workflow_anchor_path(canonical_workflow_path, opts) do
    with {:ok, anchor_root} <- workflow_anchor_root(opts) do
      {:ok,
       Path.join([
         anchor_root,
         "state-root-binding-#{workflow_identity(canonical_workflow_path)}.json"
       ])}
    end
  end

  defp workflow_anchor_root(opts) do
    case Keyword.fetch(opts, :anchor_root) do
      {:ok, anchor_root} when is_binary(anchor_root) ->
        PathSafety.canonical_local_path(anchor_root)

      {:ok, _invalid_anchor_root} ->
        {:error, :invalid_state_root_binding_options}

      :error ->
        PathSafety.canonical_local_path(default_workflow_anchor_root())
    end
  end

  defp default_workflow_anchor_root do
    Application.get_env(
      :symphony_elixir,
      :state_anchor_root,
      Path.join([System.user_home!(), ".symphony", "state", @workflow_anchor_directory])
    )
  end

  defp prepare_binding_marker(path) do
    case Storage.prepare(path) do
      {:ok, binding} ->
        validate_binding_pending_state(binding)

      {:error, {:hard_link_not_allowed, ^path}} ->
        with :ok <- recover_published_binding_marker(path),
             {:ok, binding} <- Storage.prepare(path) do
          validate_binding_pending_state(binding)
        else
          {:error, reason} -> {:error, {:state_root_binding_unsafe, reason}}
        end

      {:error, reason} ->
        {:error, {:state_root_binding_unsafe, reason}}
    end
  end

  defp validate_binding_pending_state(binding) do
    pending_path = binding_pending_path(binding.path)

    case {File.lstat(binding.path), File.lstat(pending_path)} do
      {{:ok, _final_stat}, {:ok, _pending_stat}} ->
        {:error, {:state_root_binding_unsafe, {:binding_publication_conflict, binding.path}}}

      {_final_status, _pending_status} ->
        {:ok, binding}
    end
  end

  defp recover_published_binding_marker(path) do
    pending_path = binding_pending_path(path)

    with {:ok, %File.Stat{type: :regular} = final_stat} <- File.lstat(path),
         {:ok, %File.Stat{type: :regular} = pending_stat} <- File.lstat(pending_path),
         true <- same_file_identity?(final_stat, pending_stat),
         :ok <- File.rm(pending_path),
         :ok <- Storage.sync_directory(Path.dirname(path)) do
      :ok
    else
      false -> {:error, {:binding_publication_conflict, path}}
      {:ok, %File.Stat{type: type}} -> {:error, {:binding_publication_not_regular, path, type}}
      {:error, reason} -> {:error, {:binding_publication_recovery_failed, path, reason}}
    end
  end

  defp read_binding_marker(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = marker} -> {:ok, {:existing, marker}}
          _ -> {:error, {:invalid_state_root_binding, path}}
        end

      {:error, reason} ->
        {:error, {:state_root_binding_unreadable, path, reason}}
    end
  end

  defp validate_existing_anchor(:missing, _workflow_path, _canonical_root), do: :ok

  defp validate_existing_anchor({:existing, marker}, workflow_path, canonical_root) do
    expected_identity = workflow_identity(workflow_path)

    case marker do
      %{
        "schema_version" => @state_root_binding_schema_version,
        "workflow_identity" => ^expected_identity,
        "state_root" => stored_root,
        "state_root_identity" => stored_identity
      }
      when is_binary(stored_root) and is_list(stored_identity) ->
        if stored_root == canonical_root do
          :ok
        else
          {:error, {:state_root_migration_required, stored_root, canonical_root}}
        end

      _ ->
        {:error, {:invalid_state_root_binding, :workflow_anchor}}
    end
  end

  defp validate_root_identity_for_anchor(:missing, _root_binding), do: :ok

  defp validate_root_identity_for_anchor({:existing, marker}, root_binding) do
    if marker["state_root_identity"] == identity_list(root_binding.root_identity) do
      :ok
    else
      {:error, {:state_root_identity_changed, root_binding.root}}
    end
  end

  defp validate_existing_root_marker(path, workflow_path, root_identity, anchor_status) do
    case read_binding_marker(path) do
      {:ok, root_status} ->
        validate_root_marker_status(
          root_status,
          workflow_identity(workflow_path),
          root_identity,
          anchor_status,
          Path.dirname(path)
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_root_marker_status(:missing, _workflow_identity, _root_identity, :missing, _root),
    do: {:ok, :missing}

  defp validate_root_marker_status(:missing, _workflow_identity, _root_identity, _anchor_status, root),
    do: {:error, {:state_root_binding_missing, root}}

  defp validate_root_marker_status(
         {:existing,
          %{
            "schema_version" => @state_root_binding_schema_version,
            "workflow_identity" => workflow_identity,
            "state_root_identity" => stored_identity
          }} = root_status,
         workflow_identity,
         root_identity,
         _anchor_status,
         root
       )
       when is_list(stored_identity) do
    if stored_identity == identity_list(root_identity) do
      {:ok, root_status}
    else
      {:error, {:state_root_identity_changed, root}}
    end
  end

  defp validate_root_marker_status(
         {:existing, %{"workflow_identity" => stored_identity}},
         _workflow_identity,
         _root_identity,
         _anchor_status,
         root
       )
       when is_binary(stored_identity),
       do: {:error, {:state_root_binding_conflict, root}}

  defp validate_root_marker_status({:existing, _marker}, _workflow_identity, _root_identity, _anchor_status, _root),
    do: {:error, {:invalid_state_root_binding, :state_root_marker}}

  defp write_missing_anchor(:missing, binding, workflow_path, canonical_root, root_identity, opts) do
    marker = %{
      "schema_version" => @state_root_binding_schema_version,
      "workflow_identity" => workflow_identity(workflow_path),
      "state_root" => canonical_root,
      "state_root_identity" => identity_list(root_identity)
    }

    write_binding_marker(binding, marker, opts, :anchor)
  end

  defp write_missing_anchor(
         {:existing, _marker},
         binding,
         _workflow_path,
         _canonical_root,
         _root_identity,
         _opts
       ),
       do: finalize_binding_marker(binding)

  defp write_missing_root_marker(:missing, :missing, binding, workflow_path, opts) do
    marker = %{
      "schema_version" => @state_root_binding_schema_version,
      "workflow_identity" => workflow_identity(workflow_path),
      "state_root_identity" => identity_list(binding.root_identity)
    }

    write_binding_marker(binding, marker, opts, :root)
  end

  defp write_missing_root_marker(
         _anchor_status,
         {:existing, _marker},
         binding,
         _workflow_path,
         _opts
       ),
       do: finalize_binding_marker(binding)

  defp write_binding_marker(binding, marker, opts, marker_kind) do
    payload = Jason.encode!(marker)

    with {:ok, pending_binding} <- prepare_pending_binding(binding),
         :ok <- write_or_recover_pending_marker(pending_binding, marker, payload),
         :ok <- binding_checkpoint(opts, marker_fault_stage(marker_kind, :prepared)),
         :ok <- publish_pending_binding(pending_binding, binding),
         :ok <- binding_checkpoint(opts, marker_fault_stage(marker_kind, :published)),
         :ok <- remove_published_pending(pending_binding) do
      finalize_binding_marker(binding)
    end
  end

  defp prepare_pending_binding(binding) do
    case Storage.prepare(binding_pending_path(binding.path)) do
      {:ok, pending_binding} -> {:ok, pending_binding}
      {:error, reason} -> {:error, {:state_root_binding_unsafe, reason}}
    end
  end

  defp write_or_recover_pending_marker(pending_binding, marker, payload) do
    case File.read(pending_binding.path) do
      {:error, :enoent} ->
        write_pending_marker(pending_binding, payload)

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, ^marker} -> finalize_pending_marker(pending_binding)
          {:ok, _other_marker} -> {:error, {:state_root_binding_pending_conflict, pending_binding.path}}
          _invalid_or_partial -> replace_partial_pending_marker(pending_binding, payload)
        end

      {:error, reason} ->
        {:error, {:state_root_binding_unreadable, pending_binding.path, reason}}
    end
  end

  defp replace_partial_pending_marker(pending_binding, payload) do
    with :ok <- File.rm(pending_binding.path),
         :ok <- Storage.sync_directory(pending_binding.root),
         {:ok, replacement_binding} <- Storage.prepare(pending_binding.path) do
      write_pending_marker(replacement_binding, payload)
    else
      {:error, reason} ->
        {:error, {:state_root_binding_pending_recovery_failed, pending_binding.path, reason}}
    end
  end

  defp write_pending_marker(pending_binding, payload) do
    case File.open(pending_binding.path, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        write_result =
          with :ok <- File.chmod(pending_binding.path, 0o600),
               :ok <- :file.write(device, payload) do
            :file.sync(device)
          end

        close_result = File.close(device)

        case {write_result, close_result} do
          {:ok, :ok} ->
            finalize_pending_marker(pending_binding)

          {{:error, reason}, _close_result} ->
            {:error, {:state_root_binding_write_failed, pending_binding.path, reason}}

          {_write_result, {:error, reason}} ->
            {:error, {:state_root_binding_write_failed, pending_binding.path, reason}}
        end

      {:error, :eexist} ->
        {:error, {:state_root_binding_race, pending_binding.path}}

      {:error, reason} ->
        {:error, {:state_root_binding_write_failed, pending_binding.path, reason}}
    end
  end

  defp finalize_pending_marker(pending_binding) do
    with :ok <- finalize_storage_binding(pending_binding) do
      sync_binding_directory(pending_binding)
    end
  end

  defp publish_pending_binding(pending_binding, binding) do
    case File.ln(pending_binding.path, binding.path) do
      :ok -> :ok
      {:error, :eexist} -> {:error, {:state_root_binding_race, binding.path}}
      {:error, reason} -> {:error, {:state_root_binding_publish_failed, binding.path, reason}}
    end
  end

  defp remove_published_pending(pending_binding) do
    case File.rm(pending_binding.path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:state_root_binding_pending_cleanup_failed, pending_binding.path, reason}}
    end
  end

  defp sync_binding_directory(binding) do
    case Storage.sync_directory(binding.root) do
      :ok -> :ok
      {:error, reason} -> {:error, {:state_root_binding_sync_failed, binding.root, reason}}
    end
  end

  defp finalize_binding_marker(binding) do
    with :ok <- finalize_storage_binding(binding) do
      sync_binding_directory(binding)
    end
  end

  defp finalize_storage_binding(binding) do
    case Storage.finalize(binding) do
      :ok -> :ok
      {:error, reason} -> {:error, {:state_root_binding_unsafe, reason}}
    end
  end

  defp marker_fault_stage(:root, :prepared), do: :root_marker_prepared
  defp marker_fault_stage(:root, :published), do: :root_marker_published
  defp marker_fault_stage(:anchor, :prepared), do: :anchor_marker_prepared
  defp marker_fault_stage(:anchor, :published), do: :anchor_marker_published

  defp binding_pending_path(path), do: path <> @binding_pending_suffix

  defp same_file_identity?(left, right) do
    {left.major_device, left.minor_device, left.inode} ==
      {right.major_device, right.minor_device, right.inode}
  end

  defp binding_checkpoint(opts, stage) do
    case Keyword.get(opts, :fault_after) do
      ^stage -> {:error, {:state_root_binding_fault_injected, stage}}
      nil -> :ok
      configured_stage when configured_stage in @binding_fault_stages -> :ok
      _invalid_stage -> {:error, :invalid_state_root_binding_options}
    end
  end

  defp workflow_identity(canonical_workflow_path) do
    canonical_workflow_path
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp identity_list({major_device, minor_device, inode}), do: [major_device, minor_device, inode]

  defp canonical_path(path) do
    with {:ok, resolved_path} <- PathSafety.canonical_local_path(path),
         :ok <- ensure_regular_or_absent(resolved_path) do
      {:ok, resolved_path}
    else
      {:error, reason} -> {:error, {:unsafe_ledger_path, reason}}
    end
  end

  defp ensure_regular_or_absent(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, path, type}}
      {:error, reason} -> {:error, {path, reason}}
    end
  end
end
