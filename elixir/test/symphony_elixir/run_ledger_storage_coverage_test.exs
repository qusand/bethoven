defmodule SymphonyElixir.RunLedgerStorageCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLedger

  setup do
    assert {:ok, tmp_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())

    root =
      Path.join(
        tmp_root,
        "symphony-run-ledger-storage-coverage-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "exposes durable issue lookup and rejects recovery without an intent", %{root: root} do
    path = ledger_path(root, "issue")
    close_ledger_on_exit(path)

    assert {:ok, nil} = RunLedger.issue(path, "missing-issue")

    event = dispatch_event("issue", "issue-lookup")
    assert {:ok, _snapshot} = RunLedger.append(path, event)

    assert {:ok, issue} = RunLedger.issue(path, "issue-lookup")
    assert issue.status == "dispatching"

    assert {:error, {:no_recovery_intent, "run-issue:dispatch"}} = RunLedger.recover(path, event)

    assert :ok = RunLedger.close(path)
  end

  test "explicit recovery rejects a conflicting payload then completes an intent-only commit", %{root: root} do
    path = ledger_path(root, "intent")
    close_ledger_on_exit(path)

    event = dispatch_event("intent", "issue-intent", worker_host: "worker-one")

    assert {:error, {:commit_unknown, "run-intent:dispatch"}} =
             RunLedger.append(path, event,
               fault_injector: fn
                 :before_commit -> {:error, :interrupted}
                 _phase -> :ok
               end
             )

    conflicting_event = put_in(event, [:data, :worker_host], "worker-two")

    assert {:error, {:duplicate_event_conflict, "run-intent:dispatch"}} =
             RunLedger.recover(path, conflicting_event)

    assert {:ok, %{issues: %{"issue-intent" => %{status: "dispatching"}}}} = RunLedger.recover(path, event)
    assert {:ok, :healthy} = RunLedger.health(path)
    assert {:error, {:no_recovery_intent, "run-intent:dispatch"}} = RunLedger.recover(path, event)
  end

  test "explicit recovery completes checkpoint-only and identity-written commit boundaries", %{root: root} do
    path = ledger_path(root, "boundaries")
    close_ledger_on_exit(path)

    checkpoint_event = dispatch_event("checkpoint", "issue-checkpoint")

    assert {:error, {:commit_unknown, "run-checkpoint:dispatch"}} =
             RunLedger.append(path, checkpoint_event,
               fault_injector: fn
                 :after_checkpoint -> {:error, :checkpoint_ack_lost}
                 _phase -> :ok
               end
             )

    assert {:ok, %{issues: %{"issue-checkpoint" => %{status: "dispatching"}}}} =
             RunLedger.recover(path, checkpoint_event)

    committed_event = dispatch_event("committed", "issue-committed")

    assert {:error, {:commit_unknown, "run-committed:dispatch"}} =
             RunLedger.append(path, committed_event,
               fault_injector: fn
                 :after_commit -> {:error, :identity_ack_lost}
                 _phase -> :ok
               end
             )

    assert {:error, {:ledger_recovery_required, "run-committed:dispatch"}} =
             RunLedger.recover(path, committed_event)

    assert :ok = RunLedger.close(path)
    assert {:ok, %{issues: %{"issue-committed" => %{status: "dispatching"}}}} = RunLedger.load(path)
  end

  test "fault injection treats nil as success and unknown values as an uncertain commit", %{root: root} do
    path = ledger_path(root, "faults")
    close_ledger_on_exit(path)

    assert {:ok, _snapshot} =
             RunLedger.append(path, dispatch_event("nil", "issue-nil"), fault_injector: fn _phase -> nil end)

    assert {:error, {:commit_unknown, "run-other:dispatch"}} =
             RunLedger.append(path, dispatch_event("other", "issue-other"),
               fault_injector: fn
                 :before_commit -> :unexpected
                 _phase -> :ok
               end
             )
  end

  test "rejects a private regular file that is not a DETS ledger", %{root: root} do
    path = ledger_path(root, "not-a-dets-table")
    close_ledger_on_exit(path)

    File.write!(path, "not a DETS table")
    assert :ok = File.chmod(path, 0o600)

    assert {:error, {:ledger_writer_unavailable, {:ledger_open_failed, {:dets_open_failed, _reason}}}} =
             RunLedger.load(path)
  end

  test "latches a replaced leaf across all read and write calls", %{root: root} do
    path = ledger_path(root, "replaced")
    moved_path = path <> ".original"
    close_ledger_on_exit(path)

    event = dispatch_event("replaced", "issue-replaced")
    assert {:ok, _snapshot} = RunLedger.append(path, event)

    assert :ok = File.rename(path, moved_path)
    assert :ok = File.cp(moved_path, path)
    assert :ok = File.chmod(path, 0o600)

    assert_unsafe_leaf(path, RunLedger.issue(path, "issue-replaced"))
    assert_unsafe_leaf(path, RunLedger.health(path))
    assert_unsafe_leaf(path, RunLedger.load(path))
    assert_unsafe_leaf(path, RunLedger.recover(path, event))

    assert_unsafe_leaf(
      path,
      RunLedger.append(path, %{
        event_id: "run-replaced:worker-started",
        issue_id: "issue-replaced",
        issue_identifier: "ISSUE-REPLACED",
        type: :worker_started,
        data: %{run_id: "run-replaced"}
      })
    )
  end

  test "fails closed for missing, nonprivate, nonregular, and hard-linked leaves", %{root: root} do
    for {name, mutate, expected_reason} <- [
          {"missing", &File.rm!/1, fn path -> {:ledger_file_missing, path} end},
          {"mode", fn path -> File.chmod!(path, 0o644) end, fn path -> {:ledger_file_not_private, path} end},
          {"directory",
           fn path ->
             File.rm!(path)
             File.mkdir!(path)
           end, fn path -> {:not_a_regular_file, path, :directory} end},
          {"hard-link", fn path -> File.ln!(path, path <> ".link") end, fn path -> {:hard_link_not_allowed, path} end}
        ] do
      path = ledger_path(root, name)
      close_ledger_on_exit(path)

      assert {:ok, _snapshot} = RunLedger.append(path, dispatch_event(name, "issue-#{name}"))
      assert :ok = mutate.(path)

      assert {:error, {:unsafe_ledger_path, reason}} = RunLedger.load(path)
      assert reason == expected_reason.(path)
    end
  end

  test "starts a standalone ledger supervisor with its registry and writer domain", %{root: root} do
    application_supervisor = SymphonyElixir.Supervisor
    ledger_supervisor = SymphonyElixir.RunLedger.Supervisor
    path = ledger_path(root, "standalone-supervisor")

    assert {^ledger_supervisor, previous_pid, :supervisor, _modules} =
             Enum.find(Supervisor.which_children(application_supervisor), fn
               {id, _pid, _type, _modules} -> id == ledger_supervisor
             end)

    assert :ok = Supervisor.terminate_child(application_supervisor, ledger_supervisor)

    on_exit(fn ->
      stop_if_alive(ledger_supervisor)

      case Enum.find(Supervisor.which_children(application_supervisor), fn
             {id, _pid, _type, _modules} -> id == ledger_supervisor
           end) do
        {^ledger_supervisor, :undefined, :supervisor, _modules} ->
          _ = Supervisor.restart_child(application_supervisor, ledger_supervisor)

        _ ->
          :ok
      end
    end)

    assert {:ok, standalone_pid} = SymphonyElixir.RunLedger.Supervisor.start_link()
    refute standalone_pid == previous_pid
    assert is_pid(Process.whereis(SymphonyElixir.RunLedger.Registry))
    assert is_pid(Process.whereis(SymphonyElixir.RunLedger.WriterSupervisor))

    assert {:ok, _snapshot} = RunLedger.append(path, dispatch_event("standalone", "issue-standalone"))
    assert :ok = Supervisor.stop(standalone_pid)
  end

  defp dispatch_event(run_id, issue_id, extra_data \\ []) do
    %{
      event_id: "run-#{run_id}:dispatch",
      issue_id: issue_id,
      issue_identifier: String.upcase(issue_id),
      type: :dispatch,
      data: Map.merge(%{run_id: "run-#{run_id}"}, Map.new(extra_data))
    }
  end

  defp ledger_path(root, name), do: Path.join(root, "#{name}.dets")

  defp close_ledger_on_exit(path) do
    on_exit(fn ->
      _ = RunLedger.close(path)
    end)
  end

  defp assert_unsafe_leaf(path, result) do
    assert {:error, {:unsafe_ledger_path, {:ledger_file_identity_changed, ^path}}} = result
  end

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Supervisor.stop(pid)
      nil -> :ok
    end
  end
end
