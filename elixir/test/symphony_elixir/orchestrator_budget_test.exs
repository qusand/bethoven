defmodule SymphonyElixir.OrchestratorBudgetTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{IssueBudget, RunLedger}

  test "budget policy normalizes persisted values and retains the stricter ceiling" do
    now = DateTime.utc_now()

    assert %{
             max_sessions: 3,
             max_turns: nil,
             max_tokens: 10,
             max_wall_time_ms: nil,
             max_consecutive_failures: 2
           } =
             IssueBudget.merge_stricter(
               IssueBudget.normalize(%{"max_sessions" => "3", "max_tokens" => 10}),
               %{max_sessions: 5, max_turns: nil, max_tokens: 20, max_wall_time_ms: nil, max_consecutive_failures: 2}
             )

    assert :max_wall_time_ms =
             IssueBudget.exhaustion_reason(
               %{"first_started_at" => DateTime.add(now, -1_000, :millisecond) |> DateTime.to_iso8601()},
               %{max_wall_time_ms: 1_000},
               now
             )
  end

  test "issue lifetime budget checks use persisted cumulative counters" do
    now = DateTime.utc_now()

    assert :max_sessions =
             Orchestrator.issue_budget_exhaustion_for_test(
               %{session_count: 2, turn_count: 0, total_tokens: 0, consecutive_failures: 0},
               %{
                 max_sessions: 2,
                 max_turns: nil,
                 max_tokens: nil,
                 max_wall_time_ms: nil,
                 max_consecutive_failures: nil
               },
               now
             )

    assert :max_turns =
             Orchestrator.issue_budget_exhaustion_for_test(
               %{session_count: 1, turn_count: 3, total_tokens: 0, consecutive_failures: 0},
               %{
                 max_sessions: nil,
                 max_turns: 3,
                 max_tokens: nil,
                 max_wall_time_ms: nil,
                 max_consecutive_failures: nil
               },
               now
             )

    assert :max_tokens =
             Orchestrator.issue_budget_exhaustion_for_test(
               %{session_count: 1, turn_count: 1, total_tokens: 10, consecutive_failures: 0},
               %{
                 max_sessions: nil,
                 max_turns: nil,
                 max_tokens: 10,
                 max_wall_time_ms: nil,
                 max_consecutive_failures: nil
               },
               now
             )

    assert :max_consecutive_failures =
             Orchestrator.issue_budget_exhaustion_for_test(
               %{session_count: 1, turn_count: 1, total_tokens: 1, consecutive_failures: 2},
               %{
                 max_sessions: nil,
                 max_turns: nil,
                 max_tokens: nil,
                 max_wall_time_ms: nil,
                 max_consecutive_failures: 2
               },
               now
             )

    assert :max_wall_time_ms =
             Orchestrator.issue_budget_exhaustion_for_test(
               %{
                 session_count: 1,
                 turn_count: 1,
                 total_tokens: 1,
                 consecutive_failures: 0,
                 first_started_at: DateTime.add(now, -1_000, :millisecond) |> DateTime.to_iso8601()
               },
               %{
                 max_sessions: nil,
                 max_turns: nil,
                 max_tokens: nil,
                 max_wall_time_ms: 1_000,
                 max_consecutive_failures: nil
               },
               now
             )
  end

  test "budget exhausted issue snapshots survive an orchestrator restart" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-budget-#{System.unique_integer([:positive])}")
    state_root = Path.join(workspace_root, "state")
    ledger_path = RunLedger.default_path(state_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: workspace_root,
      state_root: state_root,
      issue_max_sessions: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-budget",
        identifier: "MT-BUDGET",
        title: "Budget handoff",
        state: "In Progress",
        dispatchable: true
      }
    ])

    assert {:ok, _snapshot} =
             RunLedger.append(ledger_path, %{
               event_id: "run-budget:dispatch",
               issue_id: "issue-budget",
               issue_identifier: "MT-BUDGET",
               type: :dispatch,
               data: %{run_id: "run-budget", budget: %{max_sessions: 1}}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(ledger_path, %{
               event_id: "run-budget:exhausted",
               issue_id: "issue-budget",
               issue_identifier: "MT-BUDGET",
               type: :budget_exhausted,
               data: %{reason: "max_sessions"}
             })

    orchestrator_name = Module.concat(__MODULE__, :RestartedBudgetOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      File.rm_rf(workspace_root)
    end)

    assert %{blocked: [blocked]} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert blocked.issue_id == "issue-budget"
    assert blocked.identifier == "MT-BUDGET"
    assert blocked.error =~ "budget exhausted"
  end

  test "an unresolved ledger intent prevents an orchestrator restart until exact recovery" do
    context = configure_budget!()
    issue = budget_issue("issue-ledger-restart", "MT-LEDGER-RESTART")

    first_pid = start_budget_orchestrator!(Module.concat(__MODULE__, :LedgerHealthyOrchestrator))

    event = %{
      event_id: "run-ledger-restart:dispatch",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      type: :dispatch,
      data: %{run_id: "run-ledger-restart"}
    }

    assert {:error, {:commit_unknown, "run-ledger-restart:dispatch"}} =
             RunLedger.append(context.ledger_path, event,
               fault_injector: fn
                 :before_commit -> {:error, :simulated_crash}
                 _phase -> :ok
               end
             )

    :ok = GenServer.stop(first_pid, :normal)

    restart_name = Module.concat(__MODULE__, :LedgerRecoveryRequiredOrchestrator)
    result_ref = make_ref()
    test_pid = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(test_pid, {result_ref, Orchestrator.start_link(name: restart_name)})
    end)

    assert_receive {^result_ref, {:error, {:run_ledger_unavailable, {:ledger_recovery_required, ["run-ledger-restart:dispatch"]}}}}, 1_000

    assert {:ok, _snapshot} = RunLedger.recover(context.ledger_path, event)
    restarted_pid = start_budget_orchestrator!(restart_name)

    assert %{running: [], blocked: []} = Orchestrator.snapshot(restart_name, 1_000)
    assert Process.alive?(restarted_pid)
  end

  test "ordinary block release is durable and is not rehydrated after restart" do
    context = configure_budget!()
    issue = %{budget_issue("issue-released", "MT-RELEASED") | state: "Backlog"}
    issue_id = issue.id
    run_id = "run-released"

    append_dispatch!(context.ledger_path, issue, run_id, %{})

    assert {:ok, _snapshot} =
             RunLedger.append(context.ledger_path, %{
               event_id: "#{run_id}:blocked",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :blocked,
               data: %{run_id: run_id, error: "operator input required"}
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :ReleasedIssueOrchestrator))

    assert_eventually(fn ->
      match?(
        {:ok, %{issues: %{^issue_id => %{status: "released"}}}},
        RunLedger.load(context.ledger_path)
      )
    end)

    assert wait_for_state(pid, &(not Map.has_key?(&1.blocked, issue.id))).claimed |> MapSet.member?(issue.id) == false

    Process.exit(pid, :normal)
    restarted_pid = start_budget_orchestrator!(Module.concat(__MODULE__, :ReleasedIssueRestartedOrchestrator))

    assert wait_for_state(restarted_pid, fn state ->
             not Map.has_key?(state.blocked, issue.id) and not Map.has_key?(state.retry_attempts, issue.id)
           end)
  end

  test "aggregate token totals restore from durable issue projections" do
    context = configure_budget!()
    first = budget_issue("issue-aggregate-1", "MT-AGGREGATE-1")
    second = budget_issue("issue-aggregate-2", "MT-AGGREGATE-2")

    append_dispatch!(context.ledger_path, first, "run-aggregate-1", %{})
    append_dispatch!(context.ledger_path, second, "run-aggregate-2", %{})

    for {issue, run_id, input, output, total} <- [
          {first, "run-aggregate-1", 3, 2, 5},
          {second, "run-aggregate-2", 7, 4, 11}
        ] do
      assert {:ok, _snapshot} =
               RunLedger.append(context.ledger_path, %{
                 event_id: "#{run_id}:usage",
                 issue_id: issue.id,
                 issue_identifier: issue.identifier,
                 type: :usage,
                 data: %{run_id: run_id, input_tokens: input, output_tokens: output, total_tokens: total}
               })
    end

    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :AggregateRestoreOrchestrator))

    assert %{codex_totals: %{input_tokens: 10, output_tokens: 6, total_tokens: 16}} =
             wait_for_state(pid, fn state -> state.codex_totals.total_tokens == 16 end)
  end

  test "a stricter hot-reloaded token cap applies to an existing run" do
    context = configure_budget!()
    issue = budget_issue("issue-hot-token", "MT-HOT-TOKEN")
    run_id = "run-hot-token"

    # Keep the startup poll from dispatching a competing run. This test owns
    # the already-durable run below and drives its live usage notification.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :HotTokenBudgetOrchestrator))

    append_dispatch!(context.ledger_path, issue, run_id, %{})

    :sys.replace_state(pid, fn state ->
      Enum.each(state.retry_attempts, fn {_issue_id, retry} ->
        if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref)
      end)

      %{state | retry_attempts: %{}}
    end)

    worker_pid = spawn_budget_worker()
    install_running_entry(pid, issue, worker_pid, make_ref(), run_id)

    write_workflow_file!(Workflow.workflow_file_path(), issue_max_tokens: 10)
    send(pid, {:codex_worker_update, issue.id, run_id, canonical_usage_update(6, 4, 10)})

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    assert state.blocked[issue.id].error =~ "max_tokens"
  end

  test "a stricter hot-reloaded token cap stops an idle already-over-budget worker" do
    context = configure_budget!()
    issue = budget_issue("issue-hot-token-idle", "MT-HOT-TOKEN-IDLE")
    issue_id = issue.id
    run_id = "run-hot-token-idle"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :HotIdleTokenBudgetOrchestrator))

    append_dispatch!(context.ledger_path, issue, run_id, %{})

    assert {:ok, _snapshot} =
             RunLedger.append(context.ledger_path, %{
               event_id: "#{run_id}:usage:10",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :usage,
               data: %{run_id: run_id, input_tokens: 6, output_tokens: 4, total_tokens: 10}
             })

    worker_pid = spawn_budget_worker()
    install_running_entry(pid, issue, worker_pid, make_ref(), run_id)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(), issue_max_tokens: 5)
    send(pid, :tick)

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    assert state.blocked[issue.id].error =~ "max_tokens"
    refute Map.has_key?(state.running, issue.id)
    assert_eventually(fn -> not Process.alive?(worker_pid) end)

    assert {:ok, %{issues: %{^issue_id => durable_issue}}} = RunLedger.load(context.ledger_path)
    assert durable_issue.status == "budget_exhausted"
    assert durable_issue.usage_reconciliation == "unreconciled"
  end

  test "component-only cumulative usage advances use a distinct durable identity" do
    context = configure_budget!()
    issue = budget_issue("issue-usage-vector", "MT-USAGE-VECTOR")
    issue_id = issue.id
    run_id = "run-usage-vector"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :UsageVectorOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{})

    worker_pid = spawn_budget_worker()
    install_running_entry(pid, issue, worker_pid, make_ref(), run_id)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    send(pid, {:codex_worker_update, issue.id, run_id, canonical_usage_update(3, 2, 5)})
    send(pid, {:codex_worker_update, issue.id, run_id, canonical_usage_update(4, 2, 5)})

    state =
      wait_for_state(pid, fn state ->
        issue_run = state.issue_runs[issue.id]
        issue_run.input_tokens == 4 and issue_run.output_tokens == 2 and issue_run.total_tokens == 5
      end)

    refute Map.has_key?(state.blocked, issue.id)

    assert {:ok, %{issues: %{^issue_id => durable_issue}}} = RunLedger.load(context.ledger_path)
    assert %{input_tokens: 4, output_tokens: 2, total_tokens: 5} = durable_issue
  end

  test "terminal tracker reconciliation persists the live-session reconciliation marker before release" do
    context = configure_budget!(tracker_terminal_states: ["Closed"])
    issue = budget_issue("issue-terminal-reconciliation", "MT-TERMINAL-RECONCILIATION")
    issue_id = issue.id
    run_id = "run-terminal-reconciliation"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :TerminalReconciliationOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{})

    worker_pid = spawn_budget_worker()
    install_running_entry(pid, issue, worker_pid, make_ref(), run_id)

    updated_state =
      Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Closed"}], :sys.get_state(pid))

    :sys.replace_state(pid, fn _state -> updated_state end)
    assert_eventually(fn -> not Process.alive?(worker_pid) end)

    assert {:ok, %{issues: %{^issue_id => durable_issue}}} = RunLedger.load(context.ledger_path)
    assert durable_issue.status == "terminal"
    assert durable_issue.run_id == run_id
    assert durable_issue.usage_reconciliation == "unreconciled"
  end

  test "a stricter hot-reloaded wall-time cap reschedules an existing durable run" do
    context = configure_budget!(poll_interval_ms: 20)
    issue = budget_issue("issue-hot-wall", "MT-HOT-WALL")
    issue_id = issue.id
    run_id = "run-hot-wall"

    append_dispatch!(context.ledger_path, issue, run_id, %{})
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    _pid = start_budget_orchestrator!(Module.concat(__MODULE__, :HotWallBudgetOrchestrator))

    # Let the lifetime clock exceed the newly introduced cap. The scheduler
    # must re-read policy and schedule the already-expired deadline on its next
    # public poll cycle, rather than waiting for a future worker notification.
    Process.sleep(60)
    write_workflow_file!(Workflow.workflow_file_path(), issue_max_wall_time_ms: 20)

    assert_eventually(fn ->
      match?(
        {:ok,
         %{
           issues: %{
             ^issue_id => %{status: "budget_exhausted", terminal_reason: "max_wall_time_ms"}
           }
         }},
        RunLedger.load(context.ledger_path)
      )
    end)
  end

  test "real task-supervisor ingress keeps the last canonical high-water and marks shutdown unreconciled" do
    suffix = System.unique_integer([:positive])
    test_root = Path.join(System.tmp_dir!(), "symphony-budget-ingress-#{suffix}")
    workspace_root = Path.join(test_root, "workspaces")
    state_root = Path.join(test_root, "state")
    fake_codex = Path.join(test_root, "fake-codex")
    runtime_name = Module.concat(__MODULE__, "IngressRuntime#{suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "IngressTasks#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "IngressOrchestrator#{suffix}")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    issue = budget_issue("issue-real-ingress-#{suffix}", "MT-INGRESS-#{suffix}")
    issue_id = issue.id

    on_exit(fn ->
      if runtime_pid = Process.whereis(runtime_name) do
        Supervisor.stop(runtime_pid)
      end

      restore_memory_tracker_issues(previous_memory_issues)

      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end

      File.rm_rf(test_root)
    end)

    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    File.mkdir_p!(test_root)
    File.write!(fake_codex, fake_ingress_app_server_script())
    File.chmod!(fake_codex, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: workspace_root,
      state_root: state_root,
      poll_interval_ms: 30_000,
      max_turns: 1,
      issue_max_sessions: 1,
      codex_command: "#{fake_codex} app-server"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_pid)
    ledger_path = RunLedger.default_path(state_root)

    assert_eventually(
      fn ->
        match?(
          {:ok,
           %{
             issues: %{
               ^issue_id => %{
                 status: "budget_exhausted",
                 session_count: 1,
                 turn_count: 1,
                 input_tokens: 3,
                 output_tokens: 2,
                 total_tokens: 5,
                 thread_id: "thread-ingress",
                 session_id: "thread-ingress-turn-ingress",
                 usage_reconciliation: "unreconciled"
               }
             }
           }},
          RunLedger.load(ledger_path)
        )
      end,
      3_000
    )

    assert %{blocked: [blocked], running: [], retrying: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert blocked.issue_id == issue.id
    assert blocked.error =~ "max_sessions"
    assert Task.Supervisor.children(task_supervisor_name) == []
  end

  test "a failed task-supervisor spawn does not consume an issue session" do
    suffix = System.unique_integer([:positive])
    test_root = Path.join(System.tmp_dir!(), "symphony-budget-spawn-failure-#{suffix}")
    workspace_root = Path.join(test_root, "workspaces")
    state_root = Path.join(test_root, "state")
    task_supervisor_name = Module.concat(__MODULE__, "FullTaskSupervisor#{suffix}")
    orchestrator_name = Module.concat(__MODULE__, "SpawnFailureOrchestrator#{suffix}")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue = budget_issue("issue-spawn-failure-#{suffix}", "MT-SPAWN-FAILURE-#{suffix}")
    issue_id = issue.id

    on_exit(fn ->
      if orchestrator_pid = Process.whereis(orchestrator_name) do
        GenServer.stop(orchestrator_pid)
      end

      if task_supervisor_pid = Process.whereis(task_supervisor_name) do
        Supervisor.stop(task_supervisor_pid)
      end

      restore_memory_tracker_issues(previous_memory_issues)

      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end

      File.rm_rf(test_root)
    end)

    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: workspace_root,
      state_root: state_root,
      poll_interval_ms: 30_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, task_supervisor_pid} = Task.Supervisor.start_link(name: task_supervisor_name, max_children: 1)
    Process.unlink(task_supervisor_pid)

    assert {:ok, _blocking_task_pid} =
             Task.Supervisor.start_child(task_supervisor_name, fn ->
               receive do
                 :stop -> :ok
               end
             end)

    assert {:ok, orchestrator_pid} =
             Orchestrator.start_link(name: orchestrator_name, task_supervisor: task_supervisor_name)

    Process.unlink(orchestrator_pid)
    ledger_path = RunLedger.default_path(state_root)

    assert_eventually(
      fn ->
        match?(
          {:ok,
           %{
             issues: %{
               ^issue_id => %{
                 status: "retrying",
                 session_count: 0,
                 consecutive_failures: 1
               }
             }
           }},
          RunLedger.load(ledger_path)
        )
      end,
      3_000
    )

    assert %{retrying: [_retry], running: [], blocked: []} = Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  test "an abandoned durable run is not rehydrated after an orchestrator restart" do
    context = configure_budget!()
    issue = budget_issue("issue-abandoned", "MT-ABANDONED")
    issue_id = issue.id
    run_id = "run-abandoned"

    append_dispatch!(context.ledger_path, issue, run_id, %{})

    assert {:ok, _snapshot} =
             RunLedger.append(context.ledger_path, %{
               event_id: "#{run_id}:abandoned",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :abandoned,
               data: %{run_id: run_id, reason: "operator abandoned run"}
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_name = Module.concat(__MODULE__, :AbandonedRunRestartOrchestrator)
    _pid = start_budget_orchestrator!(orchestrator_name)

    assert %{running: [], retrying: [], blocked: []} = Orchestrator.snapshot(orchestrator_name, 1_000)

    assert {:ok, %{issues: %{^issue_id => %{status: "abandoned", run_id: ^run_id}}}} =
             RunLedger.load(context.ledger_path)
  end

  test "an ordinary blocked issue keeps its wall-time state across restart" do
    context = configure_budget!(issue_max_wall_time_ms: 100)
    issue = budget_issue("issue-blocked-wall", "MT-BLOCKED-WALL")
    issue_id = issue.id
    run_id = "run-blocked-wall"

    append_dispatch!(context.ledger_path, issue, run_id, %{max_wall_time_ms: 100})

    assert {:ok, _snapshot} =
             RunLedger.append(context.ledger_path, %{
               event_id: "#{run_id}:blocked",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :blocked,
               data: %{run_id: run_id, error: "operator input required"}
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :BlockedWallOrchestrator))

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    refute Map.has_key?(state.budget_deadlines, issue.id)

    Process.sleep(150)
    assert {:ok, %{issues: %{^issue_id => %{status: "blocked"}}}} = RunLedger.load(context.ledger_path)
  end

  test "session cap lets the final allowed session finish before blocking continuation" do
    context = configure_budget!(issue_max_sessions: 1)
    issue = budget_issue("issue-session-cap", "MT-SESSION")
    run_id = "run-session-cap"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :SessionCapOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{max_sessions: 1})
    worker_pid = spawn_budget_worker()
    ref = make_ref()

    install_running_entry(pid, issue, worker_pid, ref, run_id)

    send(pid, {:codex_worker_update, issue.id, run_id, non_usage_notification()})

    state =
      wait_for_state(pid, fn state ->
        Map.get(state.running, issue.id, %{}) |> Map.get(:last_codex_event) == :notification
      end)

    refute Map.has_key?(state.blocked, issue.id)

    send(worker_pid, :stop)
    send(pid, {:DOWN, ref, :process, worker_pid, :normal})

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    assert state.blocked[issue.id].error =~ "max_sessions"
    refute Map.has_key?(state.retry_attempts, issue.id)

    assert {:ok, snapshot} = RunLedger.load(context.ledger_path)
    assert snapshot.issues[issue.id].session_count == 1
    assert snapshot.issues[issue.id].status == "budget_exhausted"
  end

  test "turn cap lets the final allowed turn receive notifications before blocking continuation" do
    context = configure_budget!(issue_max_turns: 1)
    issue = budget_issue("issue-turn-cap", "MT-TURN")
    run_id = "run-turn-cap"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :TurnCapOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{max_turns: 1})
    worker_pid = spawn_budget_worker()
    ref = make_ref()

    install_running_entry(pid, issue, worker_pid, ref, run_id)

    send(pid, {:codex_worker_update, issue.id, run_id, session_started_update("thread-turn-cap-turn-1")})
    send(pid, {:codex_worker_update, issue.id, run_id, non_usage_notification()})

    state =
      wait_for_state(pid, fn state ->
        entry = Map.get(state.running, issue.id, %{})
        entry[:last_codex_event] == :notification and state.issue_runs[issue.id].turn_count == 1
      end)

    assert Map.has_key?(state.running, issue.id)
    refute Map.has_key?(state.blocked, issue.id)

    send(worker_pid, :stop)
    send(pid, {:DOWN, ref, :process, worker_pid, :normal})

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    assert state.blocked[issue.id].error =~ "max_turns"

    assert {:ok, snapshot} = RunLedger.load(context.ledger_path)
    assert snapshot.issues[issue.id].turn_count == 1
    assert snapshot.issues[issue.id].status == "budget_exhausted"
  end

  test "turn reservations commit before provider start and fail closed at the issue limit" do
    context = configure_budget!(issue_max_turns: 1)
    issue = budget_issue("issue-turn-reservation", "MT-TURN-RESERVATION")
    run_id = "run-turn-reservation"
    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :TurnReservationOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{max_turns: 1})
    worker_pid = spawn_turn_reservation_worker(self())
    install_running_entry(pid, issue, worker_pid, make_ref(), run_id)

    reservation = %{
      issue_id: issue.id,
      run_id: run_id,
      thread_id: "thread-reserved",
      turn_number: 1
    }

    assert {:error, :stale_turn_reservation} = Orchestrator.reserve_turn(pid, reservation)

    send(worker_pid, {:reserve_turn, pid, reservation})
    assert_receive {:turn_reservation_result, 1, :ok}, 1_000

    state = :sys.get_state(pid)
    assert state.issue_runs[issue.id].turn_count == 1
    assert state.running[issue.id].pending_turn_reservation == 1

    send(
      pid,
      {:codex_worker_update, issue.id, run_id, session_started_update("thread-reserved-turn-1")}
    )

    state =
      wait_for_state(pid, fn state ->
        entry = Map.get(state.running, issue.id, %{})
        entry[:pending_turn_reservation] == nil and entry[:session_id] == "thread-reserved-turn-1"
      end)

    assert state.issue_runs[issue.id].turn_count == 1

    send(worker_pid, {:reserve_turn, pid, %{reservation | turn_number: 2}})

    assert_receive {:turn_reservation_result, 2, {:error, {:issue_budget_exhausted, :max_turns}}},
                   1_000

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    refute Map.has_key?(state.running, issue.id)
    assert state.blocked[issue.id].error =~ "max_turns"

    assert {:ok, snapshot} = RunLedger.load(context.ledger_path)
    assert snapshot.issues[issue.id].turn_count == 1
    assert snapshot.issues[issue.id].status == "budget_exhausted"

    send(worker_pid, :stop)
  end

  test "canonical thread token totals stop an in-flight worker at the token cap" do
    context = configure_budget!(issue_max_tokens: 10)
    issue = budget_issue("issue-token-cap", "MT-TOKEN")
    run_id = "run-token-cap"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :TokenCapOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{max_tokens: 10})
    worker_pid = spawn_budget_worker()

    install_running_entry(pid, issue, worker_pid, make_ref(), run_id)

    send(pid, {:codex_worker_update, issue.id, run_id, canonical_usage_update(6, 4, 10)})

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    assert state.blocked[issue.id].error =~ "max_tokens"
    refute Map.has_key?(state.running, issue.id)
    assert_eventually(fn -> not Process.alive?(worker_pid) end)

    assert {:ok, snapshot} = RunLedger.load(context.ledger_path)
    assert snapshot.issues[issue.id].total_tokens == 10
    assert snapshot.issues[issue.id].status == "budget_exhausted"
  end

  test "wall time deadline stops an in-flight worker at the configured limit" do
    context = configure_budget!(issue_max_wall_time_ms: 200)
    issue = budget_issue("issue-wall-cap", "MT-WALL")
    run_id = "run-wall-cap"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :WallCapOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{max_wall_time_ms: 200})
    worker_pid = spawn_budget_worker()

    install_running_entry(pid, issue, worker_pid, make_ref(), run_id)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    schedule_budget_deadline_for_test(pid, issue.id, 200)

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id), 1_500)
    assert state.blocked[issue.id].error =~ "max_wall_time_ms"
    refute Map.has_key?(state.running, issue.id)
    assert_eventually(fn -> not Process.alive?(worker_pid) end)

    assert {:ok, snapshot} = RunLedger.load(context.ledger_path)
    assert snapshot.issues[issue.id].status == "budget_exhausted"
  end

  test "consecutive failure cap prevents the retry after the final allowed failure" do
    context = configure_budget!(issue_max_consecutive_failures: 1)
    issue = budget_issue("issue-failure-cap", "MT-FAILURE")
    run_id = "run-failure-cap"

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :FailureCapOrchestrator))
    append_dispatch!(context.ledger_path, issue, run_id, %{max_consecutive_failures: 1})
    worker_pid = spawn_budget_worker()
    ref = make_ref()

    install_running_entry(pid, issue, worker_pid, ref, run_id)

    send(worker_pid, {:exit, :boom})
    send(pid, {:DOWN, ref, :process, worker_pid, :boom})

    state = wait_for_state(pid, &Map.has_key?(&1.blocked, issue.id))
    assert state.blocked[issue.id].error =~ "max_consecutive_failures"
    refute Map.has_key?(state.retry_attempts, issue.id)

    assert {:ok, snapshot} = RunLedger.load(context.ledger_path)
    assert snapshot.issues[issue.id].consecutive_failures == 1
    assert snapshot.issues[issue.id].status == "budget_exhausted"
  end

  test "restart restores a persisted retry due time and claim before polling" do
    context = configure_budget!(issue_max_sessions: 3)
    issue = budget_issue("issue-retry-restart", "MT-RETRY")
    run_id = "run-retry-restart"
    due_at = DateTime.add(DateTime.utc_now(), 2, :second) |> DateTime.to_iso8601()

    append_dispatch!(context.ledger_path, issue, run_id, %{max_sessions: 3})

    assert {:ok, _snapshot} =
             RunLedger.append(context.ledger_path, %{
               event_id: "#{run_id}:failure",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :failure,
               data: %{run_id: run_id, error: "transient failure"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(context.ledger_path, %{
               event_id: "#{run_id}:retry",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :retry_scheduled,
               data: %{run_id: run_id, retry_attempt: 1, retry_due_at: due_at, error: "transient failure"}
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    pid = start_budget_orchestrator!(Module.concat(__MODULE__, :RetryRestoreOrchestrator))

    state =
      wait_for_state(pid, fn state ->
        MapSet.member?(state.claimed, issue.id) and Map.has_key?(state.retry_attempts, issue.id)
      end)

    assert %{attempt: 1, due_at: ^due_at, due_at_ms: due_at_ms} = state.retry_attempts[issue.id]
    assert due_at_ms > System.monotonic_time(:millisecond)
    refute Map.has_key?(state.running, issue.id)
  end

  test "restart durably recovers a dispatched-but-never-started worker before retrying" do
    context = configure_budget!()
    issue = budget_issue("issue-dispatch-crash", "MT-DISPATCH-CRASH")
    issue_id = issue.id
    run_id = "run-dispatch-crash"

    assert {:ok, _snapshot} =
             RunLedger.append(context.ledger_path, %{
               event_id: "#{run_id}:dispatch",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :dispatch,
               data: %{run_id: run_id}
             })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_name = Module.concat(__MODULE__, :DispatchCrashRecoveryOrchestrator)
    _pid = start_budget_orchestrator!(orchestrator_name)

    assert_eventually(fn ->
      match?(
        {:ok,
         %{
           issues: %{
             ^issue_id => %{
               status: "retrying",
               run_id: ^run_id,
               session_count: 0,
               retry_due_at: due_at
             }
           }
         }}
        when is_binary(due_at),
        RunLedger.load(context.ledger_path)
      )
    end)

    assert %{retrying: [%{issue_id: ^issue_id}], running: [], blocked: []} =
             Orchestrator.snapshot(orchestrator_name, 1_000)
  end

  defp configure_budget!(overrides \\ []) do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-budget-#{System.unique_integer([:positive])}")
    state_root = Path.join(workspace_root, "state")

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          tracker_api_token: nil,
          tracker_project_slug: nil,
          workspace_root: workspace_root,
          state_root: state_root,
          poll_interval_ms: 30_000
        ],
        overrides
      )
    )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    %{workspace_root: workspace_root, state_root: state_root, ledger_path: RunLedger.default_path(state_root)}
  end

  defp start_budget_orchestrator!(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    await_initial_poll_cycle!(pid)
    pid
  end

  defp await_initial_poll_cycle!(pid) do
    minimum_remaining_ms =
      Config.settings!().polling.interval_ms
      |> div(2)
      |> min(10_000)
      |> max(1)

    wait_for_state(pid, fn state ->
      !state.poll_check_in_progress and
        is_integer(state.next_poll_due_at_ms) and
        state.next_poll_due_at_ms - System.monotonic_time(:millisecond) >= minimum_remaining_ms
    end)
  end

  defp append_dispatch!(ledger_path, issue, run_id, budget) do
    assert {:ok, _snapshot} =
             RunLedger.append(ledger_path, %{
               event_id: "#{run_id}:dispatch",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :dispatch,
               data: %{run_id: run_id, budget: budget}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(ledger_path, %{
               event_id: "#{run_id}:worker-started",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               type: :worker_started,
               data: %{run_id: run_id}
             })
  end

  defp install_running_entry(pid, issue, worker_pid, ref, run_id) do
    ledger_path = :sys.get_state(pid).ledger_path
    assert {:ok, snapshot} = RunLedger.load(ledger_path)

    :sys.replace_state(pid, fn state ->
      running_entry = %{
        pid: worker_pid,
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        worker_host: nil,
        workspace_path: nil,
        session_id: nil,
        thread_id: nil,
        run_id: run_id,
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
        retry_attempt: 0,
        started_at: DateTime.utc_now()
      }

      %{
        state
        | running: Map.put(state.running, issue.id, running_entry),
          claimed: MapSet.put(state.claimed, issue.id),
          issue_runs: snapshot.issues
      }
    end)
  end

  defp schedule_budget_deadline_for_test(pid, issue_id, delay_ms) do
    deadline_token = make_ref()
    timer_ref = Process.send_after(pid, {:budget_deadline, issue_id, deadline_token}, delay_ms)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | budget_deadlines: Map.put(state.budget_deadlines, issue_id, %{timer_ref: timer_ref, token: deadline_token})
      }
    end)
  end

  defp budget_issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Budget coverage",
      state: "In Progress",
      url: "https://example.test/issues/#{identifier}",
      dispatchable: true
    }
  end

  defp spawn_budget_worker do
    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
          {:exit, reason} -> exit(reason)
        end
      end)

    on_exit(fn ->
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    end)

    worker_pid
  end

  defp spawn_turn_reservation_worker(parent) do
    worker_pid = spawn(fn -> turn_reservation_loop(parent) end)

    on_exit(fn ->
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    end)

    worker_pid
  end

  defp turn_reservation_loop(parent) do
    receive do
      {:reserve_turn, server, %{turn_number: turn_number} = reservation} ->
        result = Orchestrator.reserve_turn(server, reservation)
        send(parent, {:turn_reservation_result, turn_number, result})
        turn_reservation_loop(parent)

      :stop ->
        :ok
    end
  end

  defp restore_memory_tracker_issues(nil), do: Application.delete_env(:symphony_elixir, :memory_tracker_issues)
  defp restore_memory_tracker_issues(issues), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

  defp fake_ingress_app_server_script do
    """
    #!/bin/sh
    count=0

    while IFS= read -r _line; do
      count=$((count + 1))

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-ingress"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-ingress"}}}'
          printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"inputTokens":3,"outputTokens":2,"totalTokens":5}}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-ingress","turn":{"id":"turn-ingress"}}}'
          printf '%s\\n' '{"method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"inputTokens":9,"outputTokens":6,"totalTokens":15}}}}'
          exit 0
          ;;
      esac
    done
    """
  end

  defp session_started_update(session_id) do
    %{event: :session_started, session_id: session_id, thread_id: "thread-turn-cap", timestamp: DateTime.utc_now()}
  end

  defp non_usage_notification do
    %{event: :notification, payload: %{method: "item/updated"}, timestamp: DateTime.utc_now()}
  end

  defp canonical_usage_update(input_tokens, output_tokens, total_tokens) do
    %{
      event: :notification,
      payload: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => input_tokens,
              "outputTokens" => output_tokens,
              "totalTokens" => total_tokens
            }
          }
        }
      },
      timestamp: DateTime.utc_now()
    }
  end

  defp wait_for_state(pid, predicate, timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_state_until(pid, predicate, deadline_ms)
  end

  defp wait_for_state_until(pid, predicate, deadline_ms) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline_ms ->
        raise "timed out waiting for orchestrator state"

      true ->
        Process.sleep(10)
        wait_for_state_until(pid, predicate, deadline_ms)
    end
  end

  defp assert_eventually(predicate, timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    assert_eventually_until(predicate, deadline_ms)
  end

  defp assert_eventually_until(predicate, deadline_ms) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        raise "timed out waiting for condition"

      true ->
        Process.sleep(10)
        assert_eventually_until(predicate, deadline_ms)
    end
  end
end
