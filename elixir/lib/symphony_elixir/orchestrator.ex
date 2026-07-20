defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured issue tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    IssueBudget,
    RunLedger,
    SensitiveData,
    StatusDashboard,
    Tracker,
    Workflow,
    Workspace
  }

  alias SymphonyElixir.Tracker.Issue

  @continuation_retry_delay_ms 1_000
  @restart_recovery_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      ledger_path: nil,
      issue_runs: %{},
      budget_deadlines: %{},
      budget_policy: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec reserve_turn(GenServer.server(), map()) :: :ok | {:error, term()}
  def reserve_turn(server, reservation) when is_map(reservation) do
    GenServer.call(server, {:reserve_turn, reservation}, 30_000)
  catch
    :exit, reason -> {:error, {:turn_reservation_unavailable, reason}}
  end

  def reserve_turn(_server, _reservation), do: {:error, :invalid_turn_reservation}

  @impl true
  def init(opts) do
    case Config.settings() do
      {:ok, config} ->
        init_with_config(opts, config)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp init_with_config(opts, config) do
    # Scheduler state is local to this orchestrator and deliberately pinned for
    # its lifetime. Worker workspace roots may be remote and hot-reloadable,
    # neither of which is safe for durable accounting.
    ledger_path = RunLedger.default_path(config.state.root)

    case RunLedger.bind_state_root(Workflow.workflow_file_path(), config.state.root) do
      :ok -> load_initial_ledger(opts, config, ledger_path)
      {:error, reason} -> {:stop, {:state_root_binding_failed, reason}}
    end
  end

  defp load_initial_ledger(opts, config, ledger_path) do
    case RunLedger.load(ledger_path) do
      {:ok, ledger_snapshot} ->
        state = initial_state_from_ledger(opts, config, ledger_path, ledger_snapshot)
        run_terminal_workspace_cleanup()
        {:ok, schedule_tick(state, 0)}

      {:error, reason} ->
        {:stop, {:run_ledger_unavailable, reason}}
    end
  end

  defp initial_state_from_ledger(opts, config, ledger_path, ledger_snapshot) do
    now_ms = System.monotonic_time(:millisecond)

    %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor),
      ledger_path: ledger_path,
      issue_runs: ledger_snapshot.issues,
      budget_policy: Config.issue_budget(),
      codex_totals: durable_codex_totals(ledger_snapshot.issues),
      codex_rate_limits: nil
    }
    |> restore_durable_budget_blocks()
    |> restore_durable_retries()
    |> restore_budget_deadlines()
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{SensitiveData.safe_inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, run_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_binary(run_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      %{run_id: ^run_id} = running_entry ->
        runtime_info = SensitiveData.redact(runtime_info)

        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        state = %{state | running: Map.put(running, issue_id, updated_running_entry)}

        state =
          case persist_issue_event(
                 state,
                 issue_id,
                 Map.get(updated_running_entry, :identifier),
                 :runtime_info,
                 %{
                   run_id: Map.get(updated_running_entry, :run_id),
                   worker_host: Map.get(updated_running_entry, :worker_host),
                   workspace_path: Map.get(updated_running_entry, :workspace_path)
                 }
               ) do
            {:ok, updated_state} ->
              updated_state

            {:error, updated_state, reason} ->
              block_for_ledger_failure(
                updated_state,
                issue_id,
                Map.get(updated_running_entry, :identifier),
                Map.get(updated_running_entry, :issue),
                reason
              )
          end

        notify_dashboard()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, run_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      )
      when is_binary(run_id) do
    case Map.get(running, issue_id) do
      %{run_id: ^run_id} = running_entry ->
        update = SensitiveData.redact(update)
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))

        state =
          case record_codex_update_events(state, issue_id, updated_running_entry, update, token_delta) do
            {:ok, updated_state} ->
              maybe_exhaust_budget_after_codex_update(updated_state, issue_id, update)

            {:error, updated_state, reason} ->
              block_for_ledger_failure(
                updated_state,
                issue_id,
                Map.get(updated_running_entry, :identifier),
                Map.get(updated_running_entry, :issue),
                reason
              )
          end

        notify_dashboard()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, _issue_id, _run_id, _runtime_info}, state), do: {:noreply, state}

  def handle_info({:worker_runtime_info, _issue_id, _runtime_info}, state), do: {:noreply, state}

  def handle_info({:codex_worker_update, _issue_id, _run_id, _update}, state), do: {:noreply, state}

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:budget_deadline, issue_id, deadline_token}, state) do
    state =
      case Map.get(state.budget_deadlines, issue_id) do
        %{token: ^deadline_token} ->
          state
          |> clear_budget_deadline(issue_id)
          |> exhaust_issue_budget(issue_id, :max_wall_time_ms)

        _ ->
          state
      end

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{SensitiveData.safe_inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      # The public app-server protocol has canonical live usage updates but no
      # validated final-total query. Preserve the last canonical high-water and
      # make that uncertainty durable instead of manufacturing a shutdown total.
      |> record_running_lifecycle_event(issue_id, running_entry, :worker_completed, %{
        usage_reconciliation: "unreconciled"
      })
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        run_id: Map.get(running_entry, :run_id)
      })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{SensitiveData.safe_inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{SensitiveData.safe_inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    state
    |> record_running_lifecycle_event(issue_id, running_entry, :failure, %{
      error: "agent exited: #{SensitiveData.safe_inspect(reason)}"
    })
    |> schedule_issue_retry(issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{SensitiveData.safe_inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      run_id: Map.get(running_entry, :run_id)
    })
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Tracker API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Tracker project scope missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{SensitiveData.safe_inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{SensitiveData.safe_inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from issue tracker: #{SensitiveData.safe_inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{SensitiveData.safe_inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issues_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{SensitiveData.safe_inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec issue_budget_exhaustion_for_test(map(), map(), DateTime.t()) :: atom() | nil
  def issue_budget_exhaustion_for_test(issue_run, budget, %DateTime{} = now)
      when is_map(issue_run) and is_map(budget) do
    IssueBudget.exhaustion_reason(issue_run, budget, now)
  end

  defp restore_durable_budget_blocks(%State{} = state) do
    Enum.reduce(state.issue_runs, state, fn {issue_id, issue_run}, state_acc ->
      status = issue_run_value(issue_run, :status)

      if status in ["blocked", "budget_exhausted"] do
        blocked_entry = %{
          issue_id: issue_id,
          identifier: issue_run_value(issue_run, :issue_identifier) || issue_id,
          issue: nil,
          worker_host: issue_run_value(issue_run, :worker_host),
          workspace_path: issue_run_value(issue_run, :workspace_path),
          session_id: issue_run_value(issue_run, :session_id),
          error: durable_block_error(issue_run, status),
          blocked_at: durable_datetime(issue_run_value(issue_run, :last_updated_at)),
          last_codex_message: nil,
          last_codex_event: if(status == "budget_exhausted", do: :budget_exhausted, else: :blocked),
          last_codex_timestamp: durable_datetime(issue_run_value(issue_run, :last_updated_at))
        }

        %{
          state_acc
          | claimed: MapSet.put(state_acc.claimed, issue_id),
            blocked: Map.put(state_acc.blocked, issue_id, blocked_entry)
        }
      else
        state_acc
      end
    end)
  end

  defp restore_budget_deadlines(%State{} = state) do
    reschedule_budget_deadlines(state)
  end

  defp reschedule_budget_deadlines(%State{} = state) do
    Enum.reduce(state.issue_runs, state, fn {issue_id, issue_run}, state_acc ->
      if budget_deadline_eligible?(issue_run) do
        state_acc
        |> cancel_budget_deadline(issue_id)
        |> schedule_issue_budget_deadline(issue_id)
      else
        cancel_budget_deadline(state_acc, issue_id)
      end
    end)
  end

  defp budget_deadline_eligible?(issue_run) do
    issue_run_value(issue_run, :status) in ["dispatching", "running", "continuing", "failing", "retrying"]
  end

  defp restore_durable_retries(%State{} = state) do
    Enum.reduce(state.issue_runs, state, fn {issue_id, issue_run}, state_acc ->
      if recoverable_after_restart?(issue_run) do
        restore_durable_retry(state_acc, issue_id, issue_run)
      else
        state_acc
      end
    end)
  end

  defp recoverable_after_restart?(issue_run) do
    issue_run_value(issue_run, :status) in ["dispatching", "running", "failing", "retrying", "continuing"]
  end

  defp restore_durable_retry(%State{} = state, issue_id, issue_run) do
    state = persist_restart_recovery_transition(state, issue_id, issue_run)

    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      issue_run = Map.get(state.issue_runs, issue_id, issue_run)
      due_at = issue_run_value(issue_run, :retry_due_at)
      delay_ms = durable_retry_delay_ms(due_at, issue_run_value(issue_run, :status))
      retry_token = make_ref()
      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

      retry_entry = %{
        attempt: normalize_retry_attempt(integer_like(issue_run_value(issue_run, :retry_attempt))),
        timer_ref: timer_ref,
        retry_token: retry_token,
        due_at_ms: System.monotonic_time(:millisecond) + delay_ms,
        due_at: due_at,
        identifier: durable_issue_identifier(state, issue_id),
        issue_url: nil,
        error: issue_run_value(issue_run, :last_error),
        worker_host: issue_run_value(issue_run, :worker_host),
        workspace_path: issue_run_value(issue_run, :workspace_path)
      }

      %{
        state
        | claimed: MapSet.put(state.claimed, issue_id),
          retry_attempts: Map.put(state.retry_attempts, issue_id, retry_entry)
      }
    end
  end

  defp persist_restart_recovery_transition(%State{} = state, issue_id, issue_run) do
    status = issue_run_value(issue_run, :status)

    if status in ["dispatching", "running", "failing", "continuing"] do
      persist_restart_recovery_retry(state, issue_id, issue_run, status)
    else
      state
    end
  end

  defp persist_restart_recovery_retry(state, issue_id, issue_run, status) do
    identifier = durable_issue_identifier(state, issue_id)

    case issue_run_value(issue_run, :run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        persist_restart_recovery_event(state, issue_id, identifier, issue_run, status, run_id)

      _ ->
        block_for_ledger_failure(state, issue_id, identifier, nil, :missing_durable_run_id)
    end
  end

  defp persist_restart_recovery_event(state, issue_id, identifier, issue_run, status, run_id) do
    data = restart_recovery_event_data(issue_run, status, run_id)

    case persist_issue_event(
           state,
           issue_id,
           identifier,
           restart_recovery_event_type(status),
           data,
           "#{run_id}:restart-recovery"
         ) do
      {:ok, updated_state} ->
        updated_state

      {:error, updated_state, reason} ->
        block_for_ledger_failure(updated_state, issue_id, identifier, nil, reason)
    end
  end

  defp restart_recovery_event_type("continuing"), do: :continuation_scheduled
  defp restart_recovery_event_type(_status), do: :retry_scheduled

  defp restart_recovery_event_data(issue_run, status, run_id) do
    %{
      run_id: run_id,
      retry_attempt: normalize_retry_attempt(integer_like(issue_run_value(issue_run, :retry_attempt))),
      retry_due_at: restart_recovery_due_at(issue_run),
      error: issue_run_value(issue_run, :last_error),
      worker_host: issue_run_value(issue_run, :worker_host),
      workspace_path: issue_run_value(issue_run, :workspace_path)
    }
    |> maybe_mark_restart_recovery(status)
    |> maybe_mark_restart_usage_reconciliation(status)
  end

  defp maybe_mark_restart_recovery(data, status) when status in ["dispatching", "running"] do
    Map.put(data, :restart_recovery, true)
  end

  defp maybe_mark_restart_recovery(data, _status), do: data

  defp maybe_mark_restart_usage_reconciliation(data, "dispatching"), do: data

  defp maybe_mark_restart_usage_reconciliation(data, _status) do
    Map.put(data, :usage_reconciliation, "unreconciled")
  end

  defp restart_recovery_due_at(issue_run) do
    case issue_run_value(issue_run, :retry_due_at) do
      due_at when is_binary(due_at) ->
        if durable_datetime_or_nil(due_at), do: due_at, else: fresh_restart_recovery_due_at()

      _ ->
        DateTime.add(DateTime.utc_now(), @restart_recovery_delay_ms, :millisecond) |> DateTime.to_iso8601()
    end
  end

  defp fresh_restart_recovery_due_at do
    DateTime.add(DateTime.utc_now(), @restart_recovery_delay_ms, :millisecond) |> DateTime.to_iso8601()
  end

  defp durable_retry_delay_ms(due_at, _status) when is_binary(due_at) do
    case durable_datetime_or_nil(due_at) do
      %DateTime{} = due_at -> max(0, DateTime.diff(due_at, DateTime.utc_now(), :millisecond))
      nil -> @restart_recovery_delay_ms
    end
  end

  defp durable_retry_delay_ms(_due_at, _status), do: @restart_recovery_delay_ms

  defp durable_budget_error(issue_run) do
    case issue_run_value(issue_run, :terminal_reason) || issue_run_value(issue_run, :last_error) do
      reason when is_binary(reason) and reason != "" -> "issue budget exhausted: #{reason}"
      _ -> "issue budget exhausted"
    end
  end

  defp durable_block_error(issue_run, "budget_exhausted"), do: durable_budget_error(issue_run)

  defp durable_block_error(issue_run, "blocked") do
    case issue_run_value(issue_run, :last_error) do
      error when is_binary(error) and error != "" -> error
      _ -> "issue remains blocked after orchestrator restart"
    end
  end

  defp durable_datetime(%DateTime{} = datetime), do: datetime

  defp durable_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp durable_datetime(_value), do: DateTime.utc_now()

  defp durable_datetime_or_nil(%DateTime{} = datetime), do: datetime

  defp durable_datetime_or_nil(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp durable_datetime_or_nil(_value), do: nil

  defp issue_run_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp issue_run_value(_map, _key), do: nil

  defp issue_budget_for(%State{} = state, issue_id) do
    persisted_budget =
      state.issue_runs
      |> Map.get(issue_id, %{})
      |> issue_run_value(:budget)
      |> IssueBudget.normalize()

    # A policy reload may tighten an active issue immediately, but it may not
    # weaken a ceiling that was accepted when the run was dispatched.
    IssueBudget.merge_stricter(persisted_budget, Config.issue_budget())
  end

  defp reserve_turn_for_worker(%State{} = state, caller_pid, reservation)
       when is_pid(caller_pid) do
    case normalize_turn_reservation(reservation) do
      {:ok, issue_id, run_id, thread_id, turn_number} ->
        reserve_bound_worker_turn(
          state,
          caller_pid,
          issue_id,
          run_id,
          thread_id,
          turn_number
        )

      :error ->
        {:error, state, :invalid_turn_reservation}
    end
  end

  defp reserve_turn_for_worker(%State{} = state, _caller_pid, _reservation) do
    {:error, state, :invalid_turn_reservation}
  end

  defp normalize_turn_reservation(%{
         issue_id: issue_id,
         run_id: run_id,
         thread_id: thread_id,
         turn_number: turn_number
       }) do
    string_values = [issue_id, run_id, thread_id]

    if Enum.all?(string_values, &valid_reservation_string?/1) and
         is_integer(turn_number) and turn_number > 0 do
      {:ok, issue_id, run_id, thread_id, turn_number}
    else
      :error
    end
  end

  defp normalize_turn_reservation(_reservation), do: :error

  defp valid_reservation_string?(value), do: is_binary(value) and value != ""

  defp reserve_bound_worker_turn(
         state,
         caller_pid,
         issue_id,
         run_id,
         thread_id,
         turn_number
       ) do
    case Map.get(state.running, issue_id) do
      %{pid: ^caller_pid, run_id: ^run_id} = running_entry ->
        reserve_current_turn(state, issue_id, running_entry, run_id, thread_id, turn_number)

      _missing_or_stale_worker ->
        {:error, state, :stale_turn_reservation}
    end
  end

  defp reserve_current_turn(state, issue_id, running_entry, run_id, thread_id, turn_number) do
    pending_turn = Map.get(running_entry, :pending_turn_reservation)
    worker_turn_count = Map.get(running_entry, :turn_count, 0)

    cond do
      pending_turn == turn_number ->
        {:ok, state}

      not is_integer(worker_turn_count) or turn_number != worker_turn_count + 1 ->
        {:error, state, :invalid_turn_reservation_order}

      turn_budget_reached?(state, issue_id) ->
        updated_state = exhaust_issue_budget(state, issue_id, :max_turns, stop_running: false)
        {:error, updated_state, {:issue_budget_exhausted, :max_turns}}

      true ->
        persist_turn_reservation(
          state,
          issue_id,
          running_entry,
          run_id,
          thread_id,
          turn_number
        )
    end
  end

  defp turn_budget_reached?(state, issue_id) do
    issue_run = Map.get(state.issue_runs, issue_id, %{})
    budget = issue_budget_for(state, issue_id)
    IssueBudget.reached?(issue_run_value(issue_run, :turn_count), budget.max_turns)
  end

  defp persist_turn_reservation(
         state,
         issue_id,
         running_entry,
         run_id,
         thread_id,
         turn_number
       ) do
    case persist_issue_event(
           state,
           issue_id,
           Map.get(running_entry, :identifier),
           :turn_reserved,
           %{run_id: run_id, thread_id: thread_id, turn_number: turn_number},
           "#{run_id}:turn-reserved:#{turn_number}"
         ) do
      {:ok, updated_state} ->
        updated_running_entry =
          Map.merge(running_entry, %{
            thread_id: thread_id,
            turn_count: Map.get(running_entry, :turn_count, 0) + 1,
            pending_turn_reservation: turn_number,
            turn_pre_reserved: false
          })

        {:ok,
         %{
           updated_state
           | running: Map.put(updated_state.running, issue_id, updated_running_entry)
         }}

      {:error, updated_state, reason} ->
        blocked_state =
          block_for_ledger_failure(
            updated_state,
            issue_id,
            Map.get(running_entry, :identifier),
            Map.get(running_entry, :issue),
            reason,
            stop_running: false
          )

        {:error, blocked_state, {:turn_reservation_failed, reason}}
    end
  end

  defp issue_budget_reason(%State{} = state, issue_id) when is_binary(issue_id) do
    issue_run = Map.get(state.issue_runs, issue_id, %{})
    IssueBudget.exhaustion_reason(issue_run, issue_budget_for(state, issue_id), DateTime.utc_now())
  end

  # A session and turn are committed at dispatch/start, so evaluating those
  # limits on every mid-turn notification would terminate the final permitted
  # unit before it can finish. The worker receives the remaining turn allowance
  # at dispatch; session, turn, and failure caps are enforced at the next
  # dispatch/retry boundary. Token usage is the only live-update counter that
  # must stop an in-flight turn; wall time has its own deadline timer.
  defp maybe_exhaust_budget_after_codex_update(state, issue_id, _update) do
    issue_run = Map.get(state.issue_runs, issue_id, %{})
    budget = issue_budget_for(state, issue_id)

    if IssueBudget.reached?(issue_run_value(issue_run, :total_tokens), budget.max_tokens) do
      exhaust_issue_budget(state, issue_id, :max_tokens)
    else
      state
    end
  end

  defp schedule_issue_budget_deadline(%State{} = state, issue_id) when is_binary(issue_id) do
    case budget_deadline_remaining_ms(state, issue_id) do
      {:remaining, 0} -> exhaust_issue_budget(state, issue_id, :max_wall_time_ms)
      {:remaining, remaining_ms} -> register_budget_deadline(state, issue_id, remaining_ms)
      :disabled -> state
    end
  end

  defp schedule_issue_budget_deadline(state, _issue_id), do: state

  defp budget_deadline_remaining_ms(%State{} = state, issue_id) do
    limit = issue_budget_for(state, issue_id).max_wall_time_ms
    started_at = state.issue_runs |> Map.get(issue_id, %{}) |> issue_run_value(:first_started_at)

    wall_time_remaining_ms(limit, durable_datetime_or_nil(started_at))
  end

  defp wall_time_remaining_ms(limit, %DateTime{} = started_at) when is_integer(limit) and limit > 0 do
    elapsed_ms = max(0, DateTime.diff(DateTime.utc_now(), started_at, :millisecond))
    {:remaining, max(0, limit - elapsed_ms)}
  end

  defp wall_time_remaining_ms(_limit, _started_at), do: :disabled

  defp register_budget_deadline(%State{} = state, issue_id, remaining_ms)
       when is_integer(remaining_ms) and remaining_ms > 0 do
    case Map.get(state.budget_deadlines, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) ->
        state

      _ ->
        deadline_token = make_ref()
        timer_ref = Process.send_after(self(), {:budget_deadline, issue_id, deadline_token}, remaining_ms)

        %{
          state
          | budget_deadlines:
              Map.put(state.budget_deadlines, issue_id, %{
                timer_ref: timer_ref,
                token: deadline_token
              })
        }
    end
  end

  defp clear_budget_deadline(%State{} = state, issue_id) do
    %{state | budget_deadlines: Map.delete(state.budget_deadlines, issue_id)}
  end

  defp cancel_budget_deadline(%State{} = state, issue_id) do
    case Map.get(state.budget_deadlines, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)

      _ ->
        :ok
    end

    clear_budget_deadline(state, issue_id)
  end

  defp exhaust_issue_budget(%State{} = state, issue_id, reason, opts \\ []) do
    running_entry = Map.get(state.running, issue_id)
    issue = running_entry && Map.get(running_entry, :issue)
    identifier = (running_entry && Map.get(running_entry, :identifier)) || durable_issue_identifier(state, issue_id)

    data =
      %{
        reason: Atom.to_string(reason),
        terminal_reason: Atom.to_string(reason),
        run_id: running_entry && Map.get(running_entry, :run_id)
      }
      |> maybe_mark_shutdown_usage(running_entry)

    case persist_issue_event(
           state,
           issue_id,
           identifier,
           :budget_exhausted,
           data
         ) do
      {:ok, updated_state} ->
        finalize_budget_exhaustion(
          updated_state,
          issue_id,
          reason,
          running_entry,
          issue,
          identifier,
          opts
        )

      {:error, updated_state, persistence_reason} ->
        block_for_ledger_failure(
          updated_state,
          issue_id,
          identifier,
          issue,
          persistence_reason,
          opts
        )
    end
  end

  defp finalize_budget_exhaustion(
         state,
         issue_id,
         reason,
         running_entry,
         issue,
         identifier,
         opts
       ) do
    state = if is_map(running_entry), do: record_session_completion_totals(state, running_entry), else: state
    state = cancel_retry_for_budget(state, issue_id)
    state = cancel_budget_deadline(state, issue_id)

    if is_map(running_entry) and Keyword.get(opts, :stop_running, true) do
      stop_running_task(
        Map.get(running_entry, :pid),
        Map.get(running_entry, :ref),
        state.task_supervisor
      )
    end

    blocked_entry = %{
      issue_id: issue_id,
      identifier: identifier,
      issue: issue,
      worker_host: running_entry && Map.get(running_entry, :worker_host),
      workspace_path: running_entry && Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry || %{}),
      error: "issue budget exhausted: #{Atom.to_string(reason)}",
      blocked_at: DateTime.utc_now(),
      last_codex_message: running_entry && Map.get(running_entry, :last_codex_message),
      last_codex_event: :budget_exhausted,
      last_codex_timestamp: DateTime.utc_now()
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp cancel_retry_for_budget(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _ -> :ok
    end

    %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
  end

  defp durable_issue_identifier(%State{} = state, issue_id) do
    state.issue_runs
    |> Map.get(issue_id, %{})
    |> issue_run_value(:issue_identifier)
    |> case do
      identifier when is_binary(identifier) and identifier != "" -> identifier
      _ -> issue_id
    end
  end

  defp persist_issue_event(state, issue_id, identifier, type, data, event_id \\ nil)

  defp persist_issue_event(
         %State{ledger_path: path} = state,
         issue_id,
         identifier,
         type,
         data,
         event_id
       )
       when is_binary(path) and is_binary(issue_id) and is_map(data) do
    event = build_issue_event(state, issue_id, identifier, type, data, event_id)
    append_issue_event(state, path, event)
  end

  defp persist_issue_event(%State{} = state, issue_id, _identifier, _type, data, _event_id)
       when is_binary(issue_id) and is_map(data) do
    {:ok, state}
  end

  defp build_issue_event(state, issue_id, identifier, type, data, event_id) do
    run_id = issue_event_run_id(state, issue_id, data)

    %{
      event_id: event_id || new_ledger_event_id(run_id, type),
      issue_id: issue_id,
      issue_identifier: identifier,
      type: type,
      data: data
    }
  end

  defp issue_event_run_id(state, issue_id, data) do
    persisted_run_id = state.issue_runs |> Map.get(issue_id, %{}) |> issue_run_value(:run_id)

    Map.get(data, :run_id) || Map.get(data, "run_id") || persisted_run_id || issue_id
  end

  defp append_issue_event(state, path, %{issue_id: issue_id, type: type} = event) do
    case RunLedger.append(path, event) do
      {:ok, snapshot} ->
        {:ok, %{state | issue_runs: snapshot.issues}}

      {:error, reason} ->
        Logger.error(
          "Unable to persist issue ledger event issue_id=#{issue_id} event=#{type}: " <>
            SensitiveData.safe_inspect(reason)
        )

        {:error, state, reason}
    end
  end

  defp max_turns_for_worker(%State{} = state, issue_id, budget) do
    session_max_turns = Config.settings!().agent.max_turns
    completed_turns = Map.get(state.issue_runs, issue_id, %{}) |> issue_run_value(:turn_count) |> integer_like() || 0

    case budget.max_turns do
      limit when is_integer(limit) and limit > 0 -> max(1, min(session_max_turns, limit - completed_turns))
      _ -> session_max_turns
    end
  end

  defp new_run_id(issue_id) when is_binary(issue_id) do
    "#{issue_id}:#{random_identifier_suffix()}"
  end

  defp new_ledger_event_id(run_id, type) do
    "#{run_id}:#{type}:#{random_identifier_suffix()}"
  end

  defp random_identifier_suffix do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp record_issue_failure(state, issue_id, identifier, run_id, error) do
    case persist_issue_event(
           state,
           issue_id,
           identifier,
           :failure,
           %{run_id: run_id, error: error}
         ) do
      {:ok, updated_state} -> updated_state
      {:error, updated_state, reason} -> block_for_ledger_failure(updated_state, issue_id, identifier, nil, reason)
    end
  end

  defp record_running_lifecycle_event(state, issue_id, running_entry, type, data)
       when is_map(running_entry) and is_map(data) do
    data =
      if type in [:worker_completed, :failure] do
        Map.put_new(data, :usage_reconciliation, "unreconciled")
      else
        data
      end

    lifecycle_data =
      Map.merge(data, %{
        run_id: Map.get(running_entry, :run_id),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        session_id: Map.get(running_entry, :session_id),
        thread_id: Map.get(running_entry, :thread_id)
      })

    case persist_issue_event(
           state,
           issue_id,
           Map.get(running_entry, :identifier),
           type,
           lifecycle_data
         ) do
      {:ok, updated_state} ->
        updated_state

      {:error, updated_state, reason} ->
        block_for_ledger_failure(updated_state, issue_id, Map.get(running_entry, :identifier), Map.get(running_entry, :issue), reason)
    end
  end

  defp maybe_mark_shutdown_usage(data, running_entry) when is_map(data) and is_map(running_entry) do
    case Map.get(running_entry, :run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        Map.put_new(data, :usage_reconciliation, "unreconciled")

      _ ->
        data
    end
  end

  defp maybe_mark_shutdown_usage(data, _running_entry), do: data

  defp record_codex_update_events(state, issue_id, running_entry, update, token_delta) do
    records =
      []
      |> maybe_add_turn_started_record(running_entry, update)
      |> maybe_add_usage_record(running_entry, token_delta)

    Enum.reduce_while(records, {:ok, state}, fn {type, data, event_id}, {:ok, state_acc} ->
      case persist_issue_event(state_acc, issue_id, Map.get(running_entry, :identifier), type, data, event_id) do
        {:ok, updated_state} -> {:cont, {:ok, updated_state}}
        {:error, updated_state, reason} -> {:halt, {:error, updated_state, reason}}
      end
    end)
  end

  defp maybe_add_turn_started_record(records, running_entry, %{event: :session_started} = update) do
    session_id = Map.get(update, :session_id)
    run_id = Map.get(running_entry, :run_id)

    if is_binary(session_id) and is_binary(run_id) do
      type =
        if Map.get(running_entry, :turn_pre_reserved, false),
          do: :runtime_info,
          else: :turn_started

      records ++
        [
          {
            type,
            %{
              run_id: run_id,
              thread_id: Map.get(update, :thread_id),
              session_id: session_id
            },
            "#{run_id}:#{type}:#{session_id}"
          }
        ]
    else
      records
    end
  end

  defp maybe_add_turn_started_record(records, _running_entry, _update), do: records

  defp maybe_add_usage_record(records, running_entry, token_delta) do
    delta_total = Map.get(token_delta, :total_tokens, 0)
    delta_input = Map.get(token_delta, :input_tokens, 0)
    delta_output = Map.get(token_delta, :output_tokens, 0)
    run_id = Map.get(running_entry, :run_id)

    if is_binary(run_id) and delta_input + delta_output + delta_total > 0 do
      input_high_water = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
      output_high_water = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
      total_high_water = Map.get(running_entry, :codex_last_reported_total_tokens, 0)

      records ++
        [
          {
            :usage,
            %{
              run_id: run_id,
              input_tokens: delta_input,
              output_tokens: delta_output,
              total_tokens: delta_total
            },
            "#{run_id}:usage:#{input_high_water}:#{output_high_water}:#{total_high_water}"
          }
        ]
    else
      records
    end
  end

  defp block_issue_for_ledger_failure(state, %Issue{} = issue, reason) do
    block_for_ledger_failure(state, issue.id, issue.identifier, issue, reason)
  end

  defp block_for_ledger_failure(
         %State{} = state,
         issue_id,
         identifier,
         issue,
         reason,
         opts \\ []
       )
       when is_binary(issue_id) do
    Logger.error("Blocking issue because its durable ledger is unavailable issue_id=#{issue_id}: #{SensitiveData.safe_inspect(reason)}")

    running_entry = Map.get(state.running, issue_id, %{})
    state = cancel_retry_for_budget(state, issue_id) |> cancel_budget_deadline(issue_id)

    if Keyword.get(opts, :stop_running, true) do
      stop_running_task(
        Map.get(running_entry, :pid),
        Map.get(running_entry, :ref),
        state.task_supervisor
      )
    end

    identifier = identifier || Map.get(running_entry, :identifier) || durable_issue_identifier(state, issue_id)
    issue = issue || Map.get(running_entry, :issue)

    blocked_entry = %{
      issue_id: issue_id,
      identifier: identifier,
      issue: issue,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: "durable run ledger unavailable: #{SensitiveData.safe_inspect(reason)}",
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: :ledger_unavailable,
      last_codex_timestamp: DateTime.utc_now()
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue, blocked_issue_worker_host(state, issue.id))
        release_issue_claim(state, issue.id, true)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      %{pid: _pid, ref: _ref, identifier: _identifier} = running_entry ->
        terminate_running_entry(state, issue_id, cleanup_workspace, running_entry)

      _ ->
        release_issue_claim(state, issue_id, cleanup_workspace)
    end
  end

  defp terminate_running_entry(
         state,
         issue_id,
         cleanup_workspace,
         %{pid: _pid, ref: _ref, identifier: _identifier} = running_entry
       ) do
    state =
      state
      |> record_session_completion_totals(running_entry)
      |> cancel_budget_deadline(issue_id)
      |> release_issue_claim(issue_id, cleanup_workspace, running_entry)

    case Map.has_key?(state.blocked, issue_id) do
      true -> state
      false -> stop_and_remove_running_issue(state, issue_id, cleanup_workspace, running_entry)
    end
  end

  defp stop_and_remove_running_issue(
         state,
         issue_id,
         cleanup_workspace,
         %{pid: pid, ref: ref, identifier: identifier} = running_entry
       ) do
    stop_running_task(pid, ref, state.task_supervisor)
    maybe_cleanup_terminated_workspace(cleanup_workspace, running_entry, identifier)
    %{state | running: Map.delete(state.running, issue_id)}
  end

  defp maybe_cleanup_terminated_workspace(cleanup_workspace, running_entry, identifier) do
    if cleanup_workspace do
      cleanup_issue_workspace(Map.get(running_entry, :issue, identifier), Map.get(running_entry, :worker_host))
    end
  end

  defp stop_running_for_retry(%State{} = state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{pid: pid, ref: ref} = running_entry ->
        state =
          state
          |> record_session_completion_totals(running_entry)
          |> cancel_budget_deadline(issue_id)

        stop_running_task(pid, ref, state.task_supervisor)
        %{state | running: Map.delete(state.running, issue_id)}

      _ ->
        cancel_budget_deadline(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    case stall_elapsed_ms(running_entry, now) do
      elapsed_ms when is_integer(elapsed_ms) and elapsed_ms > timeout_ms ->
        handle_stalled_issue(state, issue_id, running_entry, elapsed_ms)

      _ ->
        state
    end
  end

  defp handle_stalled_issue(state, issue_id, running_entry, elapsed_ms) do
    stalled_issue = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      session_id: running_entry_session_id(running_entry),
      elapsed_ms: elapsed_ms
    }

    case input_required_blocker?(running_entry) do
      true -> block_stalled_issue(state, running_entry, stalled_issue)
      false -> retry_stalled_issue(state, running_entry, stalled_issue)
    end
  end

  defp block_stalled_issue(state, running_entry, stalled_issue) do
    error =
      blocker_error(
        running_entry,
        "stalled for #{stalled_issue.elapsed_ms}ms after Codex requested operator input"
      )

    Logger.warning(
      "Issue blocked: issue_id=#{stalled_issue.issue_id} " <>
        "issue_identifier=#{stalled_issue.identifier} session_id=#{stalled_issue.session_id} " <>
        "elapsed_ms=#{stalled_issue.elapsed_ms}; #{error}"
    )

    state
    |> record_session_completion_totals(running_entry)
    |> stop_and_block_issue(stalled_issue.issue_id, running_entry, error)
  end

  defp retry_stalled_issue(state, running_entry, stalled_issue) do
    error = "stalled for #{stalled_issue.elapsed_ms}ms without codex activity"

    Logger.warning(
      "Issue stalled: issue_id=#{stalled_issue.issue_id} " <>
        "issue_identifier=#{stalled_issue.identifier} session_id=#{stalled_issue.session_id} " <>
        "elapsed_ms=#{stalled_issue.elapsed_ms}; restarting with backoff"
    )

    state =
      record_running_lifecycle_event(state, stalled_issue.issue_id, running_entry, :failure, %{error: error})

    schedule_stalled_issue_retry(state, running_entry, stalled_issue, error)
  end

  defp schedule_stalled_issue_retry(state, running_entry, stalled_issue, error) do
    case Map.has_key?(state.blocked, stalled_issue.issue_id) do
      true ->
        state

      false ->
        state
        |> stop_running_for_retry(stalled_issue.issue_id)
        |> schedule_issue_retry(stalled_issue.issue_id, next_retry_attempt_from_running(running_entry), %{
          identifier: stalled_issue.identifier,
          issue_url: running_entry.issue.url,
          error: error,
          run_id: Map.get(running_entry, :run_id)
        })
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid, task_supervisor) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_supervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp stop_running_task(pid, ref, task_supervisor) do
    if is_pid(pid) do
      terminate_task(pid, task_supervisor)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    state
    |> cancel_budget_deadline(issue_id)
    |> block_issue_from_entry(issue_id, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    state = cancel_budget_deadline(state, issue_id)

    case persist_issue_event(
           state,
           issue_id,
           Map.get(running_entry, :identifier),
           :blocked,
           %{
             run_id: Map.get(running_entry, :run_id),
             error: error,
             worker_host: Map.get(running_entry, :worker_host),
             workspace_path: Map.get(running_entry, :workspace_path),
             session_id: running_entry_session_id(running_entry),
             thread_id: Map.get(running_entry, :thread_id),
             usage_reconciliation: "unreconciled"
           }
         ) do
      {:ok, updated_state} ->
        stop_running_task(
          Map.get(running_entry, :pid),
          Map.get(running_entry, :ref),
          updated_state.task_supervisor
        )

        blocked_entry = %{
          issue_id: issue_id,
          identifier: Map.get(running_entry, :identifier, issue_id),
          issue: Map.get(running_entry, :issue),
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path),
          session_id: running_entry_session_id(running_entry),
          error: error,
          blocked_at: DateTime.utc_now(),
          last_codex_message: Map.get(running_entry, :last_codex_message),
          last_codex_event: Map.get(running_entry, :last_codex_event),
          last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
        }

        %{
          updated_state
          | running: Map.delete(updated_state.running, issue_id),
            retry_attempts: Map.delete(updated_state.retry_attempts, issue_id),
            claimed: MapSet.put(updated_state.claimed, issue_id),
            blocked: Map.put(updated_state.blocked, issue_id, blocked_entry)
        }

      {:error, updated_state, reason} ->
        block_for_ledger_failure(
          updated_state,
          issue_id,
          Map.get(running_entry, :identifier),
          Map.get(running_entry, :issue),
          reason
        )
    end
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    Enum.all?([id, identifier, title, state_name], &present_string?/1) and
      issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issues_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{SensitiveData.safe_inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    case issue_budget_reason(state, issue.id) do
      reason when is_atom(reason) and not is_nil(reason) ->
        Logger.warning("Issue budget exhausted before dispatch: #{issue_context(issue)} reason=#{reason}")
        exhaust_issue_budget(state, issue.id, reason)

      nil ->
        recipient = self()

        case select_worker_host(state, preferred_worker_host) do
          :no_worker_capacity ->
            Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
            state

          worker_host ->
            spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
        end
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    run_id = new_run_id(issue.id)
    budget = issue_budget_for(state, issue.id)
    max_turns = max_turns_for_worker(state, issue.id, budget)

    case persist_issue_event(
           state,
           issue.id,
           issue.identifier,
           :dispatch,
           %{
             run_id: run_id,
             worker_host: worker_host,
             budget: budget,
             retry_attempt: normalize_retry_attempt(attempt)
           },
           "#{run_id}:dispatch"
         ) do
      {:error, updated_state, reason} ->
        block_issue_for_ledger_failure(updated_state, issue, reason)

      {:ok, updated_state} ->
        spawn_persisted_issue_on_worker_host(
          updated_state,
          issue,
          attempt,
          recipient,
          worker_host,
          run_id,
          budget,
          max_turns
        )
    end
  end

  defp spawn_persisted_issue_on_worker_host(
         %State{} = state,
         issue,
         attempt,
         recipient,
         worker_host,
         run_id,
         budget,
         max_turns
       ) do
    start_token = make_ref()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           receive do
             {:start_agent_run, ^start_token} ->
               AgentRunner.run(issue, recipient,
                 attempt: attempt,
                 worker_host: worker_host,
                 run_id: run_id,
                 max_turns: max_turns,
                 turn_reservation_server: recipient
               )
           end
         end) do
      {:ok, pid} ->
        case persist_issue_event(
               state,
               issue.id,
               issue.identifier,
               :worker_started,
               %{
                 run_id: run_id,
                 worker_host: worker_host,
                 budget: budget,
                 retry_attempt: normalize_retry_attempt(attempt)
               },
               "#{run_id}:worker-started"
             ) do
          {:ok, updated_state} ->
            ref = Process.monitor(pid)

            Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

            running =
              Map.put(updated_state.running, issue.id, %{
                pid: pid,
                ref: ref,
                identifier: issue.identifier,
                issue: issue,
                worker_host: worker_host,
                workspace_path: nil,
                session_id: nil,
                thread_id: nil,
                run_id: run_id,
                issue_budget: budget,
                last_codex_message: nil,
                last_codex_timestamp: nil,
                last_codex_event: nil,
                codex_app_server_pid: nil,
                codex_input_tokens: 0,
                codex_output_tokens: 0,
                codex_total_tokens: 0,
                codex_last_reported_input_tokens: 0,
                codex_last_reported_output_tokens: 0,
                codex_last_reported_total_tokens: 0,
                turn_count: 0,
                pending_turn_reservation: nil,
                turn_pre_reserved: false,
                retry_attempt: normalize_retry_attempt(attempt),
                started_at: DateTime.utc_now()
              })

            state =
              %{
                updated_state
                | running: running,
                  claimed: MapSet.put(updated_state.claimed, issue.id),
                  retry_attempts: Map.delete(updated_state.retry_attempts, issue.id)
              }
              |> schedule_issue_budget_deadline(issue.id)

            send(pid, {:start_agent_run, start_token})
            state

          {:error, updated_state, reason} ->
            stop_running_task(pid, nil, state.task_supervisor)
            block_issue_for_ledger_failure(updated_state, issue, reason)
        end

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{SensitiveData.safe_inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        state
        |> record_issue_failure(issue.id, issue.identifier, run_id, "failed to spawn agent: #{SensitiveData.safe_inspect(reason)}")
        |> schedule_issue_retry(issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{SensitiveData.safe_inspect(reason)}",
          worker_host: worker_host,
          run_id: run_id
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    cond do
      Map.has_key?(state.blocked, issue_id) ->
        state

      reason = issue_budget_reason(state, issue_id) ->
        exhaust_issue_budget(state, issue_id, reason)

      true ->
        schedule_issue_retry_within_budget(state, issue_id, attempt, metadata)
    end
  end

  defp schedule_issue_retry_within_budget(%State{} = state, issue_id, attempt, metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    due_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond) |> DateTime.to_iso8601()
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    case persist_issue_event(
           state,
           issue_id,
           identifier,
           retry_event_type(metadata),
           %{
             run_id: metadata[:run_id],
             retry_attempt: next_attempt,
             retry_due_at: due_at,
             error: error,
             worker_host: worker_host,
             workspace_path: workspace_path
           }
         ) do
      {:error, updated_state, reason} ->
        block_for_ledger_failure(updated_state, issue_id, identifier, nil, reason)

      {:ok, updated_state} ->
        schedule_persisted_issue_retry(
          updated_state,
          %{
            issue_id: issue_id,
            attempt: next_attempt,
            retry_token: retry_token,
            delay_ms: delay_ms,
            due_at_ms: due_at_ms,
            due_at: due_at,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          }
        )
    end
  end

  defp schedule_persisted_issue_retry(state, retry_schedule) do
    previous_retry = Map.get(state.retry_attempts, retry_schedule.issue_id, %{})
    old_timer = Map.get(previous_retry, :timer_ref)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref =
      Process.send_after(
        self(),
        {:retry_issue, retry_schedule.issue_id, retry_schedule.retry_token},
        retry_schedule.delay_ms
      )

    error_suffix = if is_binary(retry_schedule.error), do: " error=#{retry_schedule.error}", else: ""

    Logger.warning(
      "Retrying issue_id=#{retry_schedule.issue_id} " <>
        "issue_identifier=#{retry_schedule.identifier} in #{retry_schedule.delay_ms}ms " <>
        "(attempt #{retry_schedule.attempt})#{error_suffix}"
    )

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, retry_schedule.issue_id, %{
            attempt: retry_schedule.attempt,
            timer_ref: timer_ref,
            retry_token: retry_schedule.retry_token,
            due_at_ms: retry_schedule.due_at_ms,
            due_at: retry_schedule.due_at,
            identifier: retry_schedule.identifier,
            issue_url: retry_schedule.issue_url,
            error: retry_schedule.error,
            worker_host: retry_schedule.worker_host,
            workspace_path: retry_schedule.workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{SensitiveData.safe_inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{SensitiveData.safe_inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id, true)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_issue_or_identifier, _worker_host), do: :ok

  defp blocked_issue_worker_host(%State{} = state, issue_id) do
    state.blocked
    |> Map.get(issue_id, %{})
    |> Map.get(:worker_host)
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{SensitiveData.safe_inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id, terminal? \\ false, shutdown_entry \\ nil) do
    state = cancel_retry_for_budget(state, issue_id) |> cancel_budget_deadline(issue_id)

    if terminal? do
      persist_terminal_issue_release(state, issue_id, shutdown_entry)
    else
      persist_nonterminal_issue_release(state, issue_id, shutdown_entry)
    end
  end

  defp persist_terminal_issue_release(%State{} = state, issue_id, shutdown_entry) do
    data = shutdown_release_data(shutdown_entry)

    case persist_issue_event(state, issue_id, durable_issue_identifier(state, issue_id), :terminal, data) do
      {:ok, updated_state} -> release_issue_claim_state(updated_state, issue_id)
      {:error, updated_state, reason} -> block_for_ledger_failure(updated_state, issue_id, nil, nil, reason)
    end
  end

  defp persist_nonterminal_issue_release(%State{} = state, issue_id, shutdown_entry) do
    data = shutdown_release_data(shutdown_entry)

    case persist_issue_event(state, issue_id, durable_issue_identifier(state, issue_id), :released, data) do
      {:ok, updated_state} -> release_issue_claim_state(updated_state, issue_id)
      {:error, updated_state, reason} -> block_for_ledger_failure(updated_state, issue_id, nil, nil, reason)
    end
  end

  defp shutdown_release_data(running_entry) when is_map(running_entry) do
    %{
      run_id: Map.get(running_entry, :run_id),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      thread_id: Map.get(running_entry, :thread_id)
    }
    |> maybe_mark_shutdown_usage(running_entry)
  end

  defp shutdown_release_data(_running_entry), do: %{}

  defp release_issue_claim_state(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp retry_event_type(%{delay_type: :continuation}), do: :continuation_scheduled
  defp retry_event_type(_metadata), do: :retry_scheduled

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call({:reserve_turn, reservation}, {caller_pid, _tag}, state) do
    result = reserve_turn_for_worker(state, caller_pid, reservation)
    notify_dashboard()

    case result do
      {:ok, updated_state} -> {:reply, :ok, updated_state}
      {:error, updated_state, reason} -> {:reply, {:error, reason}, updated_state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)

    {turn_count, pending_turn_reservation, turn_pre_reserved} =
      turn_state_for_update(running_entry, update)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        thread_id: thread_id_for_update(Map.get(running_entry, :thread_id), update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count,
        pending_turn_reservation: pending_turn_reservation,
        turn_pre_reserved: turn_pre_reserved
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp thread_id_for_update(_existing, %{thread_id: thread_id}) when is_binary(thread_id), do: thread_id
  defp thread_id_for_update(existing, _update), do: existing

  defp turn_state_for_update(running_entry, %{
         event: :session_started,
         session_id: session_id
       })
       when is_binary(session_id) do
    existing_count = Map.get(running_entry, :turn_count, 0)
    existing_count = if is_integer(existing_count), do: existing_count, else: 0
    pending_turn = Map.get(running_entry, :pending_turn_reservation)

    cond do
      is_integer(pending_turn) ->
        {existing_count, nil, true}

      session_id == Map.get(running_entry, :session_id) ->
        {existing_count, nil, false}

      true ->
        {existing_count + 1, nil, false}
    end
  end

  defp turn_state_for_update(running_entry, _update) do
    existing_count = Map.get(running_entry, :turn_count, 0)
    existing_count = if is_integer(existing_count), do: existing_count, else: 0

    {
      existing_count,
      Map.get(running_entry, :pending_turn_reservation),
      false
    }
  end

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp durable_codex_totals(issue_runs) when is_map(issue_runs) do
    Enum.reduce(issue_runs, @empty_codex_totals, fn {_issue_id, issue_run}, totals ->
      %{
        totals
        | input_tokens: totals.input_tokens + (issue_run_value(issue_run, :input_tokens) |> integer_like() || 0),
          output_tokens: totals.output_tokens + (issue_run_value(issue_run, :output_tokens) |> integer_like() || 0),
          total_tokens: totals.total_tokens + (issue_run_value(issue_run, :total_tokens) |> integer_like() || 0)
      }
    end)
  end

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()
    configured_ledger_path = RunLedger.default_path(config.state.root)
    configured_budget_policy = Config.issue_budget()

    if configured_ledger_path != state.ledger_path do
      Logger.warning("Ignoring live state.root change for durable scheduler state; restart with an explicit migration to switch ledger paths")
    end

    state = %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }

    if configured_budget_policy == state.budget_policy do
      state
    else
      %{state | budget_policy: configured_budget_policy}
      |> reschedule_budget_deadlines()
      |> enforce_active_token_budgets()
    end
  end

  defp enforce_active_token_budgets(%State{} = state) do
    Enum.reduce(state.issue_runs, state, fn {issue_id, issue_run}, state_acc ->
      active? = issue_run_value(issue_run, :status) in ["dispatching", "running", "continuing", "failing", "retrying"]
      max_tokens = issue_budget_for(state_acc, issue_id).max_tokens

      if active? and IssueBudget.reached?(issue_run_value(issue_run, :total_tokens), max_tokens) do
        exhaust_issue_budget(state_acc, issue_id, :max_tokens)
      else
        state_acc
      end
    end)
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    # Only thread-level cumulative totals are canonical. A `turn/completed`
    # usage payload may be per-turn or use provider-specific semantics, so
    # treating it as a thread total would undercount later turns or double-count
    # the final reconciliation.
    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) || %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
