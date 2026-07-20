defmodule SymphonyElixir.RunLedgerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config.Schema, RunLedger}

  test "append materializes durable issue totals and ignores duplicate event ids" do
    path = ledger_path()

    assert {:ok, snapshot} =
             RunLedger.append(path, %{
               event_id: "run-1:dispatch",
               issue_id: "issue-1",
               issue_identifier: "MT-1",
               type: :dispatch,
               data: %{run_id: "run-1", worker_host: "worker-a", workspace_path: "/work/MT-1"}
             })

    assert snapshot.issues["issue-1"].session_count == 0
    assert snapshot.issues["issue-1"].status == "dispatching"

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-1:worker-started",
               issue_id: "issue-1",
               issue_identifier: "MT-1",
               type: :worker_started,
               data: %{run_id: "run-1"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-1:turn-1",
               issue_id: "issue-1",
               issue_identifier: "MT-1",
               type: :turn_started,
               data: %{run_id: "run-1", thread_id: "thread-1", session_id: "thread-1-turn-1"}
             })

    assert {:ok, snapshot} =
             RunLedger.append(path, %{
               event_id: "run-1:usage-15",
               issue_id: "issue-1",
               issue_identifier: "MT-1",
               type: :usage,
               data: %{run_id: "run-1", input_tokens: 10, output_tokens: 5, total_tokens: 15}
             })

    assert snapshot.issues["issue-1"].turn_count == 1
    assert snapshot.issues["issue-1"].total_tokens == 15
    assert snapshot.issues["issue-1"].thread_id == "thread-1"

    assert {:ok, duplicate_snapshot} =
             RunLedger.append(path, %{
               event_id: "run-1:usage-15",
               issue_id: "issue-1",
               issue_identifier: "MT-1",
               type: :usage,
               data: %{run_id: "run-1", input_tokens: 10, output_tokens: 5, total_tokens: 15}
             })

    assert duplicate_snapshot.issues["issue-1"].total_tokens == 15
    assert {:ok, loaded_snapshot} = RunLedger.load(path)
    assert loaded_snapshot.issues["issue-1"].session_count == 1
    assert loaded_snapshot.issues["issue-1"].turn_count == 1
    assert loaded_snapshot.issues["issue-1"].total_tokens == 15
  end

  test "concurrent identical appends commit one exact event" do
    path = ledger_path()

    event = %{
      event_id: "run-concurrent:dispatch",
      issue_id: "issue-concurrent",
      issue_identifier: "MT-CONCURRENT",
      type: :dispatch,
      data: %{run_id: "run-concurrent"}
    }

    tasks =
      for _ <- 1..100 do
        Task.async(fn ->
          receive do
            :append -> RunLedger.append(path, event)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :append))

    assert Enum.all?(tasks, fn task ->
             assert {:ok, _snapshot} = Task.await(task, 5_000)
           end)

    assert {:ok, snapshot} = RunLedger.load(path)
    assert snapshot.issues["issue-concurrent"].event_count == 1
    assert snapshot.issues["issue-concurrent"].version == 1
  end

  test "restarting the registry restarts its writer domain and preserves live ledger access" do
    path = ledger_path()

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-registry:dispatch",
               issue_id: "issue-registry",
               issue_identifier: "MT-REGISTRY",
               type: :dispatch,
               data: %{run_id: "run-registry"}
             })

    assert [{writer_pid, _value}] = Registry.lookup(SymphonyElixir.RunLedger.Registry, Path.expand(path))
    registry_pid = Process.whereis(SymphonyElixir.RunLedger.Registry)
    assert is_pid(registry_pid)

    assert :ok =
             Supervisor.terminate_child(
               SymphonyElixir.RunLedger.Supervisor,
               SymphonyElixir.RunLedger.Registry
             )

    assert {:ok, new_registry_pid} =
             Supervisor.restart_child(
               SymphonyElixir.RunLedger.Supervisor,
               SymphonyElixir.RunLedger.Registry
             )

    refute new_registry_pid == registry_pid

    assert_eventually_ledger(fn ->
      worker_started = %{
        event_id: "run-registry:worker-started",
        issue_id: "issue-registry",
        issue_identifier: "MT-REGISTRY",
        type: :worker_started,
        data: %{run_id: "run-registry"}
      }

      case {Process.whereis(SymphonyElixir.RunLedger.Registry), RunLedger.append(path, worker_started), RunLedger.load(path)} do
        {^new_registry_pid, {:ok, _snapshot}, {:ok, %{issues: %{"issue-registry" => %{status: "running", session_count: 1}}}}} ->
          true

        _ ->
          false
      end
    end)

    refute Process.alive?(writer_pid)
  end

  test "conflicting event IDs and delayed prior-run events cannot mutate a newer run" do
    path = ledger_path()

    dispatch_one = %{
      event_id: "run-one:dispatch",
      issue_id: "issue-causality",
      issue_identifier: "MT-CAUSAL",
      type: :dispatch,
      data: %{run_id: "run-one"}
    }

    assert {:ok, _snapshot} = RunLedger.append(path, dispatch_one)

    assert {:error, {:duplicate_event_conflict, "run-one:dispatch"}} =
             RunLedger.append(path, put_in(dispatch_one, [:data, :run_id], "different-run"))

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-one:started",
               issue_id: "issue-causality",
               issue_identifier: "MT-CAUSAL",
               type: :worker_started,
               data: %{run_id: "run-one"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-one:terminal",
               issue_id: "issue-causality",
               issue_identifier: "MT-CAUSAL",
               type: :terminal,
               data: %{run_id: "run-one", terminal_reason: "completed"}
             })

    assert {:ok, snapshot} =
             RunLedger.append(path, %{
               event_id: "run-two:dispatch",
               issue_id: "issue-causality",
               issue_identifier: "MT-CAUSAL",
               type: :dispatch,
               data: %{run_id: "run-two"}
             })

    assert snapshot.issues["issue-causality"].run_id == "run-two"
    assert snapshot.issues["issue-causality"].status == "dispatching"

    assert {:error, {:stale_or_invalid_run, "run-one"}} =
             RunLedger.append(path, %{
               event_id: "run-one:late-failure",
               issue_id: "issue-causality",
               issue_identifier: "MT-CAUSAL",
               type: :failure,
               data: %{run_id: "run-one", error: "late worker exit"}
             })

    assert {:ok, snapshot} = RunLedger.load(path)
    assert snapshot.issues["issue-causality"].run_id == "run-two"
    assert snapshot.issues["issue-causality"].status == "dispatching"
  end

  test "rejects impossible same-run lifecycle ordering while permitting recovery retries" do
    path = ledger_path()
    issue_id = "issue-transition-order"

    dispatch = fn run_id, event_id ->
      RunLedger.append(path, %{
        event_id: event_id,
        issue_id: issue_id,
        issue_identifier: "MT-ORDER",
        type: :dispatch,
        data: %{run_id: run_id}
      })
    end

    assert {:ok, _snapshot} = dispatch.("run-one", "run-one:dispatch")

    assert {:error, {:invalid_ledger_transition, "dispatching", "usage"}} =
             RunLedger.append(path, %{
               event_id: "run-one:usage-before-worker",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :usage,
               data: %{run_id: "run-one", input_tokens: 1, output_tokens: 1, total_tokens: 2}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-one:started",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :worker_started,
               data: %{run_id: "run-one"}
             })

    assert {:error, {:invalid_ledger_transition, "running", "retry_scheduled"}} =
             RunLedger.append(path, %{
               event_id: "run-one:retry-without-failure",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :retry_scheduled,
               data: %{run_id: "run-one", retry_attempt: 1}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-one:failure",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :failure,
               data: %{run_id: "run-one", error: "worker exited"}
             })

    assert {:ok, snapshot} =
             RunLedger.append(path, %{
               event_id: "run-one:retry-after-failure",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :retry_scheduled,
               data: %{run_id: "run-one", retry_attempt: 1}
             })

    assert snapshot.issues[issue_id].status == "retrying"

    assert {:error, {:invalid_ledger_transition, "retrying", "runtime_info"}} =
             RunLedger.append(path, %{
               event_id: "run-one:late-runtime",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :runtime_info,
               data: %{run_id: "run-one", session_id: "late-session"}
             })

    assert {:ok, _snapshot} = dispatch.("run-two", "run-two:dispatch")

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-two:started",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :worker_started,
               data: %{run_id: "run-two"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-two:completed",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :worker_completed,
               data: %{run_id: "run-two"}
             })

    assert {:error, {:invalid_ledger_transition, "continuing", "usage"}} =
             RunLedger.append(path, %{
               event_id: "run-two:usage-after-completion",
               issue_id: issue_id,
               issue_identifier: "MT-ORDER",
               type: :usage,
               data: %{run_id: "run-two", input_tokens: 1, output_tokens: 1, total_tokens: 2}
             })
  end

  test "a new dispatch clears prior-run metadata while preserving issue counters" do
    path = ledger_path()
    issue_id = "issue-reopen"

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-old:dispatch",
               issue_id: issue_id,
               issue_identifier: "MT-OLD",
               type: :dispatch,
               data: %{run_id: "run-old", worker_host: "old-host", workspace_path: "/old/workspace"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-old:started",
               issue_id: issue_id,
               issue_identifier: "MT-OLD",
               type: :worker_started,
               data: %{run_id: "run-old"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-old:runtime",
               issue_id: issue_id,
               issue_identifier: "MT-OLD",
               type: :runtime_info,
               data: %{run_id: "run-old", thread_id: "old-thread", session_id: "old-session"}
             })

    due_at = DateTime.add(DateTime.utc_now(), 60, :second) |> DateTime.to_iso8601()

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-old:failure",
               issue_id: issue_id,
               issue_identifier: "MT-OLD",
               type: :failure,
               data: %{run_id: "run-old", error: "old failure"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-old:retry",
               issue_id: issue_id,
               issue_identifier: "MT-OLD",
               type: :retry_scheduled,
               data: %{run_id: "run-old", retry_attempt: 1, retry_due_at: due_at, error: "old failure"}
             })

    assert {:ok, snapshot} =
             RunLedger.append(path, %{
               event_id: "run-new:dispatch",
               issue_id: issue_id,
               issue_identifier: "MT-NEW",
               type: :dispatch,
               data: %{run_id: "run-new"}
             })

    issue = snapshot.issues[issue_id]
    assert issue.run_id == "run-new"
    assert issue.issue_identifier == "MT-NEW"
    assert issue.status == "dispatching"
    assert issue.session_count == 1
    assert issue.worker_host == nil
    assert issue.workspace_path == nil
    assert issue.thread_id == nil
    assert issue.session_id == nil
    assert issue.retry_attempt == 0
    assert issue.retry_due_at == nil
    assert issue.terminal_reason == nil
    assert issue.last_error == nil
    assert issue.prompt_hash == nil
    assert issue.prompt_bytes == nil
  end

  test "rejects invalid options before touching an unsafe storage path" do
    root = Path.dirname(ledger_path())
    target = Path.join(root, "not-a-directory")
    link = Path.join(root, "unsafe-link")
    File.mkdir_p!(root)
    File.write!(target, "not a directory")
    File.ln_s!(target, link)

    assert {:error, :invalid_ledger_options} =
             RunLedger.append(
               Path.join(link, "runs.dets"),
               %{
                 event_id: "run-options:dispatch",
                 issue_id: "issue-options",
                 type: :dispatch,
                 data: %{run_id: "run-options"}
               },
               unexpected_option: true
             )
  end

  test "exact duplicate protection survives bounded history and writer restart" do
    path = ledger_path()

    dispatch = %{
      event_id: "run-replay:dispatch",
      issue_id: "issue-replay",
      issue_identifier: "MT-REPLAY",
      type: :dispatch,
      data: %{run_id: "run-replay"}
    }

    assert {:ok, _snapshot} = RunLedger.append(path, dispatch, max_events_per_issue: 1)

    assert {:ok, _snapshot} =
             RunLedger.append(
               path,
               %{
                 event_id: "run-replay:started",
                 issue_id: "issue-replay",
                 issue_identifier: "MT-REPLAY",
                 type: :worker_started,
                 data: %{run_id: "run-replay"}
               },
               max_events_per_issue: 1
             )

    assert {:ok, _snapshot} =
             RunLedger.append(
               path,
               %{
                 event_id: "run-replay:turn-1",
                 issue_id: "issue-replay",
                 issue_identifier: "MT-REPLAY",
                 type: :turn_started,
                 data: %{run_id: "run-replay", session_id: "thread-1-turn-1", thread_id: "thread-1"}
               },
               max_events_per_issue: 1
             )

    assert {:ok, snapshot} =
             RunLedger.append(
               path,
               %{
                 event_id: "run-replay:usage-9",
                 issue_id: "issue-replay",
                 issue_identifier: "MT-REPLAY",
                 type: :usage,
                 data: %{run_id: "run-replay", input_tokens: 6, output_tokens: 3, total_tokens: 9}
               },
               max_events_per_issue: 1
             )

    assert snapshot.issues["issue-replay"].event_count == 1
    assert :ok = RunLedger.close(path)

    assert {:ok, restarted_snapshot} = RunLedger.load(path)
    assert restarted_snapshot.issues["issue-replay"].session_count == 1
    assert restarted_snapshot.issues["issue-replay"].turn_count == 1
    assert restarted_snapshot.issues["issue-replay"].total_tokens == 9

    assert {:ok, replayed_snapshot} = RunLedger.append(path, dispatch, max_events_per_issue: 1)
    assert replayed_snapshot.issues["issue-replay"].version == 4
    assert replayed_snapshot.issues["issue-replay"].session_count == 1
    assert replayed_snapshot.issues["issue-replay"].turn_count == 1
    assert replayed_snapshot.issues["issue-replay"].total_tokens == 9
  end

  test "stores one checkpoint per issue and compact exact identities per event" do
    path = ledger_path()

    events = [
      %{
        event_id: "run-layout:dispatch",
        issue_id: "issue-layout",
        issue_identifier: "MT-LAYOUT",
        type: :dispatch,
        data: %{run_id: "run-layout"}
      },
      %{
        event_id: "run-layout:started",
        issue_id: "issue-layout",
        issue_identifier: "MT-LAYOUT",
        type: :worker_started,
        data: %{run_id: "run-layout"}
      },
      %{
        event_id: "run-layout:usage",
        issue_id: "issue-layout",
        issue_identifier: "MT-LAYOUT",
        type: :usage,
        data: %{run_id: "run-layout", input_tokens: 2, output_tokens: 3, total_tokens: 5}
      }
    ]

    Enum.each(events, fn event ->
      assert {:ok, _snapshot} = RunLedger.append(path, event)
    end)

    assert :ok = RunLedger.close(path)
    {:ok, table} = :dets.open_file(make_ref(), file: String.to_charlist(path), type: :set)
    records = :dets.foldl(fn record, acc -> [record | acc] end, [], table)
    :ok = :dets.close(table)

    assert [{{:checkpoint, "issue-layout"}, checkpoint}] =
             Enum.filter(records, &match?({{:checkpoint, _issue_id}, _checkpoint}, &1))

    assert checkpoint["projection"].total_tokens == 5

    event_records = Enum.filter(records, &match?({{:event, _event_id}, _identity}, &1))
    assert length(event_records) == length(events)

    assert Enum.all?(event_records, fn {{:event, _event_id}, identity_record} ->
             Map.keys(identity_record) |> MapSet.new() == MapSet.new(["schema_version", "identity"])
           end)
  end

  test "restart automatically reconciles a committed intent exactly once" do
    path = ledger_path()

    event = %{
      event_id: "run-recovery:dispatch",
      issue_id: "issue-recovery",
      issue_identifier: "MT-RECOVERY",
      type: :dispatch,
      data: %{run_id: "run-recovery"}
    }

    assert {:error, {:commit_unknown, "run-recovery:dispatch"}} =
             RunLedger.append(path, event,
               fault_injector: fn
                 :after_commit -> {:error, :lost_sync_ack}
                 _phase -> :ok
               end
             )

    assert {:ok, {:recovery_required, ["run-recovery:dispatch"]}} = RunLedger.health(path)
    assert :ok = RunLedger.close(path)

    assert {:ok, snapshot} = RunLedger.load(path)
    assert snapshot.issues["issue-recovery"].version == 1
    assert {:ok, :healthy} = RunLedger.health(path)

    assert {:ok, duplicate_snapshot} = RunLedger.append(path, event)
    assert duplicate_snapshot.issues["issue-recovery"].version == 1
  end

  test "restart automatically reconciles an intent-only crash boundary exactly once" do
    path = ledger_path()

    event = %{
      event_id: "run-intent:dispatch",
      issue_id: "issue-intent",
      issue_identifier: "MT-INTENT",
      type: :dispatch,
      data: %{run_id: "run-intent"}
    }

    assert {:error, {:commit_unknown, "run-intent:dispatch"}} =
             RunLedger.append(path, event,
               fault_injector: fn
                 :before_commit -> {:error, :simulated_crash}
                 _phase -> :ok
               end
             )

    assert :ok = RunLedger.close(path)
    assert {:ok, snapshot} = RunLedger.load(path)
    assert snapshot.issues["issue-intent"].version == 1
    assert {:ok, :healthy} = RunLedger.health(path)

    assert {:ok, duplicate_snapshot} = RunLedger.append(path, event)
    assert duplicate_snapshot.issues["issue-intent"].version == 1
  end

  test "restart automatically completes a checkpoint-written identity-missing intent exactly once" do
    path = ledger_path()

    event = %{
      event_id: "run-checkpoint:dispatch",
      issue_id: "issue-checkpoint",
      issue_identifier: "MT-CHECKPOINT",
      type: :dispatch,
      data: %{run_id: "run-checkpoint"}
    }

    assert {:error, {:commit_unknown, "run-checkpoint:dispatch"}} =
             RunLedger.append(path, event,
               fault_injector: fn
                 :after_checkpoint -> {:error, :lost_identity_ack}
                 _phase -> :ok
               end
             )

    assert :ok = RunLedger.close(path)
    assert {:ok, snapshot} = RunLedger.load(path)
    assert snapshot.issues["issue-checkpoint"].version == 1
    assert {:ok, :healthy} = RunLedger.health(path)

    assert {:ok, duplicate_snapshot} = RunLedger.append(path, event)
    assert duplicate_snapshot.issues["issue-checkpoint"].version == 1
  end

  test "invalid append options are rejected before unsafe path inspection" do
    root = Path.dirname(ledger_path())
    unsafe_path = Path.join([root, "redirect", "runs.dets"])
    File.mkdir_p!(root)
    assert :ok = File.ln_s(Path.join(root, "outside"), Path.join(root, "redirect"))

    assert {:error, :invalid_ledger_options} =
             RunLedger.append(
               unsafe_path,
               %{
                 event_id: "run-options:dispatch",
                 issue_id: "issue-options",
                 issue_identifier: "MT-OPTIONS",
                 type: :dispatch,
                 data: %{run_id: "run-options"}
               },
               max_event_bytes: 0
             )
  end

  test "default local state roots are namespaced by canonical workflow identity" do
    root = Path.dirname(ledger_path())
    File.mkdir_p!(root)
    workflow_path = Path.join(root, "WORKFLOW.md")
    other_workflow_path = Path.join(root, "OTHER_WORKFLOW.md")
    File.write!(workflow_path, "---\n---\n")
    File.write!(other_workflow_path, "---\n---\n")

    assert {:ok, settings} = Schema.parse(%{})

    assert {:ok, %{state: %{root: state_root}}} =
             Schema.with_state_root(settings, Path.join([root, ".", "WORKFLOW.md"]))

    assert {:ok, %{state: %{root: same_state_root}}} = Schema.with_state_root(settings, workflow_path)
    assert {:ok, %{state: %{root: other_state_root}}} = Schema.with_state_root(settings, other_workflow_path)

    assert state_root == same_state_root
    refute state_root == other_state_root
    assert state_root =~ "/.symphony/state/"
  end

  test "refuses symlinked storage roots and creates owner-only ledger storage" do
    root = Path.dirname(ledger_path())
    outside = Path.join(root, "outside")
    link = Path.join(root, "state-link")
    linked_path = Path.join(link, "runs.dets")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    assert :ok = File.ln_s(outside, link)

    assert {:error, {:unsafe_ledger_path, {:symlink_not_allowed, _path}}} =
             RunLedger.append(linked_path, %{
               event_id: "run-symlink:dispatch",
               issue_id: "issue-symlink",
               type: :dispatch,
               data: %{run_id: "run-symlink"}
             })

    secure_path = Path.join(root, "state/runs.dets")

    assert {:ok, _snapshot} =
             RunLedger.append(secure_path, %{
               event_id: "run-permissions:dispatch",
               issue_id: "issue-permissions",
               type: :dispatch,
               data: %{run_id: "run-permissions"}
             })

    assert {:ok, file_stat} = File.stat(secure_path)
    assert {:ok, directory_stat} = File.stat(Path.dirname(secure_path))
    assert Bitwise.band(file_stat.mode, 0o777) == 0o600
    assert Bitwise.band(directory_stat.mode, 0o777) == 0o700
  end

  test "rejects an explicit state root that traverses a symlink" do
    root = Path.dirname(ledger_path())
    outside = Path.join(root, "outside")
    linked_root = Path.join(root, "state-link")
    workflow_path = Path.join(root, "WORKFLOW.md")

    File.mkdir_p!(outside)
    File.write!(workflow_path, "---\n---\n")
    assert :ok = File.ln_s(outside, linked_root)
    assert {:ok, settings} = Schema.parse(%{"state" => %{"root" => linked_root}})

    assert {:error, {:invalid_state_root, {:symlink_not_allowed, ^linked_root}}} =
             Schema.with_state_root(settings, workflow_path)
  end

  test "binds a workflow to one durable state root and rejects root reuse or migration" do
    root = Path.dirname(ledger_path())
    workflow_one = Path.join(root, "WORKFLOW-one.md")
    workflow_two = Path.join(root, "WORKFLOW-two.md")
    state_root_one = Path.join(root, "state-one")
    state_root_two = Path.join(root, "state-two")
    anchor_root = Path.join(root, "anchors")

    on_exit(fn -> File.rm_rf(anchor_root) end)

    File.mkdir_p!(root)
    File.write!(workflow_one, "---\n---\n")
    File.write!(workflow_two, "---\n---\n")

    assert :ok = RunLedger.bind_state_root(workflow_one, state_root_one, anchor_root: anchor_root)

    assert {:error, {:state_root_migration_required, ^state_root_one, ^state_root_two}} =
             RunLedger.bind_state_root(workflow_one, state_root_two, anchor_root: anchor_root)

    refute File.exists?(state_root_two)

    assert {:error, {:state_root_binding_conflict, ^state_root_one}} =
             RunLedger.bind_state_root(workflow_two, state_root_one, anchor_root: anchor_root)
  end

  test "state-root binding recovers after either durable creation boundary" do
    root = Path.dirname(ledger_path())
    anchor_root = Path.join(root, "anchors")
    workflow_one = Path.join(root, "WORKFLOW-one.md")
    workflow_two = Path.join(root, "WORKFLOW-two.md")
    state_root_one = Path.join(root, "state-one")
    state_root_two = Path.join(root, "state-two")
    File.mkdir_p!(root)
    File.write!(workflow_one, "---\n---\n")
    File.write!(workflow_two, "---\n---\n")

    assert {:error, {:state_root_binding_fault_injected, :root_marker_written}} =
             RunLedger.bind_state_root(workflow_one, state_root_one,
               anchor_root: anchor_root,
               fault_after: :root_marker_written
             )

    assert File.exists?(Path.join(state_root_one, ".symphony-workflow-binding.json"))
    assert Path.wildcard(Path.join(anchor_root, "*.json")) == []
    assert :ok = RunLedger.bind_state_root(workflow_one, state_root_one, anchor_root: anchor_root)

    assert {:error, {:state_root_binding_fault_injected, :anchor_marker_written}} =
             RunLedger.bind_state_root(workflow_two, state_root_two,
               anchor_root: anchor_root,
               fault_after: :anchor_marker_written
             )

    assert File.exists?(Path.join(state_root_two, ".symphony-workflow-binding.json"))
    assert length(Path.wildcard(Path.join(anchor_root, "*.json"))) == 2
    assert :ok = RunLedger.bind_state_root(workflow_two, state_root_two, anchor_root: anchor_root)
  end

  test "state-root binding atomically recovers before publication and before directory sync" do
    root = Path.dirname(ledger_path())

    stages = [
      :root_marker_prepared,
      :root_marker_published,
      :anchor_marker_prepared,
      :anchor_marker_published
    ]

    Enum.each(stages, fn stage ->
      case_root = Path.join(root, Atom.to_string(stage))
      workflow = Path.join(case_root, "WORKFLOW.md")
      state_root = Path.join(case_root, "state")
      anchor_root = Path.join(case_root, "anchors")
      root_marker = Path.join(state_root, ".symphony-workflow-binding.json")
      root_pending = root_marker <> ".pending-v1"

      File.mkdir_p!(case_root)
      File.write!(workflow, "---\n---\n")

      assert {:error, {:state_root_binding_fault_injected, ^stage}} =
               RunLedger.bind_state_root(workflow, state_root,
                 anchor_root: anchor_root,
                 fault_after: stage
               )

      {final_marker, pending_marker} =
        if stage in [:root_marker_prepared, :root_marker_published] do
          {root_marker, root_pending}
        else
          [anchor_pending] = Path.wildcard(Path.join(anchor_root, "*.pending-v1"))
          {String.trim_trailing(anchor_pending, ".pending-v1"), anchor_pending}
        end

      if stage in [:root_marker_prepared, :anchor_marker_prepared] do
        refute File.exists?(final_marker)
        assert File.exists?(pending_marker)

        # A process death while writing the private temporary file can leave a
        # partial journal. With no published final marker, retry may replace it.
        File.write!(pending_marker, "{partial")
      else
        assert File.exists?(final_marker)
        assert File.exists?(pending_marker)
        assert {:ok, final_stat} = File.stat(final_marker)
        assert {:ok, pending_stat} = File.stat(pending_marker)
        assert final_stat.inode == pending_stat.inode
        assert final_stat.links == 2
      end

      assert :ok = RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)
      assert File.exists?(root_marker)
      assert Path.wildcard(Path.join(case_root, "**/*.pending-v1")) == []

      [anchor_marker] = Path.wildcard(Path.join(anchor_root, "*.json"))
      assert {:ok, %File.Stat{links: 1}} = File.stat(root_marker)
      assert {:ok, %File.Stat{links: 1}} = File.stat(anchor_marker)
    end)
  end

  test "fails closed when a bound state root marker is removed or its directory is replaced" do
    root = Path.dirname(ledger_path())
    workflow = Path.join(root, "WORKFLOW.md")
    state_root = Path.join(root, "state")
    anchor_root = Path.join(root, "anchors")
    marker_path = Path.join(state_root, ".symphony-workflow-binding.json")

    on_exit(fn -> File.rm_rf(anchor_root) end)

    File.mkdir_p!(root)
    File.write!(workflow, "---\n---\n")
    assert :ok = RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)
    assert :ok = File.rm(marker_path)

    assert {:error, {:state_root_binding_missing, ^state_root}} =
             RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)
  end

  test "binds a writable state root when the workflow directory is readable but not writable" do
    root = Path.dirname(ledger_path())
    workflow_directory = Path.join(root, "read-only-workflow")
    workflow_path = Path.join(workflow_directory, "WORKFLOW.md")
    state_root = Path.join(root, "state")
    anchor_root = Path.join(root, "anchors")

    File.mkdir_p!(workflow_directory)
    File.write!(workflow_path, "---\n---\n")
    assert :ok = File.chmod(workflow_directory, 0o500)

    on_exit(fn ->
      if File.exists?(workflow_directory), do: File.chmod(workflow_directory, 0o700)
      File.rm_rf(anchor_root)
    end)

    assert :ok = RunLedger.bind_state_root(workflow_path, state_root, anchor_root: anchor_root)
    assert File.exists?(Path.join(state_root, ".symphony-workflow-binding.json"))
    assert Path.wildcard(Path.join(anchor_root, "state-root-binding-*.json")) != []
    assert {:ok, anchor_stat} = File.stat(anchor_root)
    assert Bitwise.band(anchor_stat.mode, 0o777) == 0o700
    refute File.exists?(Path.join(workflow_directory, ".symphony-state"))
  end

  test "latches a writer when its storage root is replaced after opening" do
    path = ledger_path()
    state_root = Path.dirname(path)
    moved_root = state_root <> "-moved"

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-storage:dispatch",
               issue_id: "issue-storage",
               type: :dispatch,
               data: %{run_id: "run-storage"}
             })

    assert :ok = File.rename(state_root, moved_root)
    assert :ok = File.mkdir(state_root)

    assert {:error, {:unsafe_ledger_path, {:storage_identity_changed, ^state_root}}} =
             RunLedger.append(path, %{
               event_id: "run-storage:worker-started",
               issue_id: "issue-storage",
               type: :worker_started,
               data: %{run_id: "run-storage"}
             })

    assert {:error, {:unsafe_ledger_path, {:storage_identity_changed, ^state_root}}} = RunLedger.load(path)
    refute File.exists?(Path.join(state_root, "runs.dets"))
    assert :ok = RunLedger.close(path)
  end

  test "rejects a replaced ledger leaf before acknowledging an event through an open DETS handle" do
    path = ledger_path()
    moved_path = path <> ".v1"

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-leaf:dispatch",
               issue_id: "issue-leaf",
               type: :dispatch,
               data: %{run_id: "run-leaf"}
             })

    assert :ok = File.rename(path, moved_path)
    assert :ok = File.cp(moved_path, path)
    assert :ok = File.chmod(path, 0o600)

    assert {:error, {:unsafe_ledger_path, {:ledger_file_identity_changed, ^path}}} =
             RunLedger.append(path, %{
               event_id: "run-leaf:worker-started",
               issue_id: "issue-leaf",
               type: :worker_started,
               data: %{run_id: "run-leaf"}
             })

    assert {:error, {:unsafe_ledger_path, {:ledger_file_identity_changed, ^path}}} = RunLedger.load(path)
    assert :ok = RunLedger.close(path)

    assert {:ok, restarted_snapshot} = RunLedger.load(path)
    assert restarted_snapshot.issues["issue-leaf"].status == "dispatching"
    assert restarted_snapshot.issues["issue-leaf"].version == 1
  end

  test "rejects hard-linked ledger files and writable non-sticky ancestors" do
    root = Path.dirname(ledger_path())
    hard_link_source = Path.join(root, "source.dets")
    hard_link_path = Path.join(root, "hard-link.dets")
    unsafe_parent = Path.join(root, "unsafe-parent")
    unsafe_path = Path.join(unsafe_parent, "runs.dets")

    File.mkdir_p!(root)
    File.write!(hard_link_source, "not a ledger")
    assert :ok = File.ln(hard_link_source, hard_link_path)

    assert {:error, {:ledger_writer_unavailable, {:ledger_open_failed, hard_link_error}}} =
             RunLedger.load(hard_link_path)

    assert {:unsafe_ledger_path, {:hard_link_not_allowed, ^hard_link_path}} = hard_link_error

    assert :ok = File.mkdir(unsafe_parent)
    assert :ok = File.chmod(unsafe_parent, 0o777)

    assert {:error, {:ledger_writer_unavailable, {:ledger_open_failed, ancestor_error}}} =
             RunLedger.load(unsafe_path)

    assert {:unsafe_ledger_path, {:writable_storage_ancestor, ^unsafe_parent}} = ancestor_error
  end

  test "append redacts sensitive values and caps retained events per issue" do
    path = ledger_path()

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-2:dispatch",
               issue_id: "issue-2",
               issue_identifier: "MT-2",
               type: :dispatch,
               data: %{run_id: "run-2"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-2:worker-started",
               issue_id: "issue-2",
               issue_identifier: "MT-2",
               type: :worker_started,
               data: %{run_id: "run-2"}
             })

    for sequence <- 1..4 do
      {type, data} =
        if sequence == 1 do
          {:failure,
           %{
             run_id: "run-2",
             error: "api_key=must-not-persist x-api-key=also-secret Bearer top-secret"
           }}
        else
          {:note, %{detail: "retained-event-#{sequence}"}}
        end

      assert {:ok, _snapshot} =
               RunLedger.append(
                 path,
                 %{
                   event_id: "run-2:event-#{sequence}",
                   issue_id: "issue-2",
                   issue_identifier: "MT-2",
                   type: type,
                   data: data
                 },
                 max_events_per_issue: 2,
                 max_event_bytes: 1_024
               )
    end

    assert {:ok, contents} = File.read(path)
    refute contents =~ "must-not-persist"
    refute contents =~ "also-secret"
    refute contents =~ "top-secret"
    assert {:ok, snapshot} = RunLedger.load(path)
    assert snapshot.issues["issue-2"].event_count <= 2
  end

  test "redacts error and terminal reason fields without weakening meaningful duplicate conflicts" do
    path = ledger_path()

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-redaction:dispatch",
               issue_id: "issue-redaction",
               issue_identifier: "MT-REDACTION",
               type: :dispatch,
               data: %{run_id: "run-redaction"}
             })

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-redaction:started",
               issue_id: "issue-redaction",
               issue_identifier: "MT-REDACTION",
               type: :worker_started,
               data: %{run_id: "run-redaction"}
             })

    failure = %{
      event_id: "run-redaction:failure",
      issue_id: "issue-redaction",
      issue_identifier: "MT-REDACTION",
      type: :failure,
      data: %{run_id: "run-redaction", error: "apiKey=first-secret context=worker-crashed"}
    }

    assert {:ok, _snapshot} = RunLedger.append(path, failure)

    # Secret-bearing diagnostics are intentionally non-semantic. Retrying the
    # same event with a rotated credential is an exact no-op, while a distinct
    # safe diagnostic remains a duplicate conflict.
    assert {:ok, _snapshot} =
             RunLedger.append(path, put_in(failure, [:data, :error], "apiKey=rotated-secret context=worker-crashed"))

    assert {:error, {:duplicate_event_conflict, "run-redaction:failure"}} =
             RunLedger.append(path, put_in(failure, [:data, :error], "apiKey=rotated-secret context=other-failure"))

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "run-redaction:terminal",
               issue_id: "issue-redaction",
               issue_identifier: "MT-REDACTION",
               type: :terminal,
               data: %{run_id: "run-redaction", terminal_reason: "Authorization: Bearer terminal-secret"}
             })

    assert {:ok, contents} = File.read(path)
    refute contents =~ "first-secret"
    refute contents =~ "rotated-secret"
    refute contents =~ "terminal-secret"

    assert {:ok, snapshot} = RunLedger.load(path)
    assert snapshot.issues["issue-redaction"].last_error =~ "[REDACTED]"
    assert snapshot.issues["issue-redaction"].terminal_reason =~ "[REDACTED]"
  end

  test "load rejects semantically malformed durable entries instead of silently losing budget state" do
    path = ledger_path()
    File.mkdir_p!(Path.dirname(path))

    {:ok, table} = :dets.open_file(make_ref(), file: String.to_charlist(path), type: :set)
    :ok = :dets.insert(table, {{:event, "bad-event"}, %{"schema_version" => 99}})
    :ok = :dets.sync(table)
    :ok = :dets.close(table)

    assert {:error, {:ledger_writer_unavailable, {:ledger_open_failed, {:invalid_persisted_commit, _reason}}}} =
             RunLedger.load(path)
  end

  test "load refuses a legacy ledger layout instead of silently resetting it" do
    path = ledger_path()
    File.mkdir_p!(Path.dirname(path))

    {:ok, table} = :dets.open_file(make_ref(), file: String.to_charlist(path), type: :set)
    :ok = :dets.insert(table, {{:event, "legacy-event"}, %{"schema_version" => 3}})
    :ok = :dets.sync(table)
    :ok = :dets.close(table)

    assert {:error, {:ledger_writer_unavailable, {:ledger_open_failed, {:ledger_migration_required, 3, 4}}}} = RunLedger.load(path)
  end

  test "load rejects malformed durable recovery intents" do
    path = ledger_path()
    File.mkdir_p!(Path.dirname(path))

    {:ok, table} = :dets.open_file(make_ref(), file: String.to_charlist(path), type: :set)
    :ok = :dets.insert(table, {{:intent, "bad-intent"}, %{"schema_version" => RunLedger.schema_version()}})
    :ok = :dets.sync(table)
    :ok = :dets.close(table)

    assert {:error, {:ledger_writer_unavailable, {:ledger_open_failed, {:invalid_persisted_intent, _reason}}}} =
             RunLedger.load(path)
  end

  defp ledger_path do
    assert {:ok, tmp_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())

    root =
      Path.join(
        tmp_root,
        "symphony-run-ledger-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    Path.join(root, "runs.dets")
  end

  defp assert_eventually_ledger(predicate, timeout_ms \\ 1_000) when is_function(predicate, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually_ledger(predicate, deadline)
  end

  defp do_assert_eventually_ledger(predicate, deadline) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for ledger condition")
      else
        Process.sleep(10)
        do_assert_eventually_ledger(predicate, deadline)
      end
    end
  end
end
