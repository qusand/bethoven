defmodule SymphonyElixir.RunLedgerApiCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLedger

  test "uses public issue and close APIs for absent and materialized ledgers" do
    path = ledger_path()

    assert :ok = RunLedger.close(ledger_path())
    assert {:ok, nil} = RunLedger.issue(path, "missing-issue")
    assert :ok = RunLedger.close(path)

    assert {:ok, _snapshot} =
             RunLedger.append(path, %{
               event_id: "api-coverage:dispatch",
               issue_id: "api-coverage-issue",
               issue_identifier: "API-COVERAGE",
               type: :dispatch,
               data: %{run_id: "api-coverage"}
             })

    assert {:ok, %{issue_id: "api-coverage-issue", status: "dispatching"}} =
             RunLedger.issue(path, "api-coverage-issue")

    assert :ok = RunLedger.close(path)
  end

  test "rejects an unresolvable workflow identity when deriving a default state root" do
    root = temporary_root()
    loop = Path.join(root, "workflow-loop")

    File.mkdir_p!(root)
    assert :ok = File.ln_s("workflow-loop", loop)

    assert {:error, {:invalid_workflow_identity, {:path_canonicalize_failed, ^loop, :too_many_symlink_hops}}} =
             RunLedger.default_state_root(loop)
  end

  test "exposes storage preparation and finalization errors through public APIs" do
    root = temporary_root()
    path = Path.join(root, "state/runs.dets")
    blocker = Path.join(root, "not-a-directory")

    File.mkdir_p!(root)

    assert :ok = RunLedger.ensure_storage_path(path)
    assert {:ok, binding} = RunLedger.open_storage(path)

    assert {:error, {:unsafe_ledger_path, {:ledger_file_missing, ^path}}} =
             RunLedger.bind_storage_leaf(binding)

    assert {:error, {:unsafe_ledger_path, {:ledger_file_missing, ^path}}} =
             RunLedger.finalize_storage(binding)

    File.write!(blocker, "not a directory")

    assert {:error, {:unsafe_ledger_path, {_path, :enotdir}}} =
             RunLedger.ensure_storage_path(Path.join(blocker, "runs.dets"))
  end

  test "validates persisted commits through the public validation seam" do
    assert {:error, :invalid_commit} = RunLedger.validate_persisted_commit(:not_a_commit)
  end

  test "rejects invalid public state-root options before creating durable markers" do
    root = temporary_root()
    workflow = Path.join(root, "WORKFLOW.md")
    state_root = Path.join(root, "state")

    File.mkdir_p!(root)
    File.write!(workflow, "---\n---\n")

    assert {:error, :invalid_state_root_binding_options} =
             RunLedger.bind_state_root(workflow, state_root, :not_a_keyword_list)

    assert {:error, :invalid_state_root_binding_options} =
             RunLedger.bind_state_root(workflow, state_root, anchor_root: :not_a_path)
  end

  test "exposes the public recovery result when no uncertain commit exists" do
    path = ledger_path()

    event = %{
      event_id: "api-coverage:recover",
      issue_id: "api-coverage-recover",
      issue_identifier: "API-RECOVER",
      type: :dispatch,
      data: %{run_id: "api-coverage-recover"}
    }

    assert {:error, {:no_recovery_intent, "api-coverage:recover"}} = RunLedger.recover(path, event)
  end

  test "bind state root fails closed for unsafe and malformed markers" do
    root = temporary_root()
    workflow = Path.join(root, "WORKFLOW.md")
    state_root = Path.join(root, "state")
    anchor_root = Path.join(root, "anchors")

    File.mkdir_p!(root)
    File.write!(workflow, "---\n---\n")
    File.write!(anchor_root, "blocks marker directory creation")

    assert {:error, {:state_root_binding_unsafe, {_path, :enotdir}}} =
             RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)

    assert :ok = File.rm(anchor_root)
    assert :ok = RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)

    anchor_marker = anchor_marker_path(anchor_root)
    File.write!(anchor_marker, "not-json")

    assert {:error, {:invalid_state_root_binding, ^anchor_marker}} =
             RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)

    File.write!(anchor_marker, "{}")

    assert {:error, {:invalid_state_root_binding, :workflow_anchor}} =
             RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)
  end

  test "bind state root detects changed root identity and malformed root markers" do
    root = temporary_root()
    workflow = Path.join(root, "WORKFLOW.md")
    state_root = Path.join(root, "state")
    anchor_root = Path.join(root, "anchors")

    File.mkdir_p!(root)
    File.write!(workflow, "---\n---\n")
    assert :ok = RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)

    root_marker = Path.join(state_root, ".symphony-workflow-binding.json")
    File.write!(root_marker, "{}")

    assert {:error, {:invalid_state_root_binding, :state_root_marker}} =
             RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)

    assert :ok = File.rm(root_marker)
    replaced_state_root = state_root <> "-replaced"
    assert :ok = File.rename(state_root, replaced_state_root)
    assert :ok = File.mkdir(state_root)

    assert {:error, {:state_root_identity_changed, ^state_root}} =
             RunLedger.bind_state_root(workflow, state_root, anchor_root: anchor_root)
  end

  test "rejects a directory where a regular ledger file is required" do
    directory_path = Path.join(temporary_root(), "not-a-ledger-file")
    File.mkdir_p!(directory_path)

    assert {:error, {:unsafe_ledger_path, {:not_a_regular_file, ^directory_path, :directory}}} =
             RunLedger.load(directory_path)
  end

  test "returns a public availability error when a registered writer exits during a call" do
    path = ledger_path()
    canonical_path = Path.expand(path)
    parent = self()

    writer =
      spawn(fn ->
        {:ok, _} = Registry.register(SymphonyElixir.RunLedger.Registry, canonical_path, :test_writer)
        send(parent, {:writer_registered, self()})

        receive do
          {:"$gen_call", _from, _request} -> exit(:simulated_writer_exit)
        end
      end)

    assert_receive {:writer_registered, ^writer}

    assert {:error, {:ledger_writer_unavailable, _reason}} =
             RunLedger.issue(path, "writer-exits")

    refute Process.alive?(writer)
  end

  test "returns registry-unavailable errors through public issue and close APIs" do
    path = ledger_path()
    supervisor = SymphonyElixir.RunLedger.Supervisor
    registry = SymphonyElixir.RunLedger.Registry

    assert is_pid(Process.whereis(registry))
    assert :ok = Supervisor.terminate_child(supervisor, registry)

    on_exit(fn ->
      if is_nil(Process.whereis(registry)) do
        case Supervisor.restart_child(supervisor, registry) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :running} -> :ok
        end
      end
    end)

    assert {:error, {:ledger_writer_unavailable, :registry_unavailable}} =
             RunLedger.issue(path, "registry-unavailable")

    assert {:error, {:ledger_writer_unavailable, :registry_unavailable}} =
             RunLedger.close(path)

    assert {:ok, _pid} = Supervisor.restart_child(supervisor, registry)
  end

  test "returns availability errors when the writer supervisor disappears mid-call" do
    path = ledger_path()
    ledger_supervisor = SymphonyElixir.RunLedger.Supervisor
    writer_supervisor = SymphonyElixir.RunLedger.WriterSupervisor
    registry = SymphonyElixir.RunLedger.Registry

    assert :ok = Supervisor.terminate_child(ledger_supervisor, writer_supervisor)

    on_exit(fn ->
      if is_nil(Process.whereis(writer_supervisor)) do
        case Supervisor.restart_child(ledger_supervisor, writer_supervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :running} -> :ok
        end
      end
    end)

    assert {:error, {:ledger_writer_unavailable, _reason}} = RunLedger.load(path)

    parent = self()

    fake_writer =
      spawn(fn ->
        {:ok, _} = Registry.register(registry, Path.expand(path), :test_writer)
        send(parent, {:close_writer_registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(fake_writer), do: Process.exit(fake_writer, :kill)
    end)

    assert_receive {:close_writer_registered, ^fake_writer}

    assert {:error, {:ledger_writer_unavailable, _reason}} = RunLedger.close(path)

    send(fake_writer, :stop)
    assert {:ok, _pid} = Supervisor.restart_child(ledger_supervisor, writer_supervisor)
  end

  defp ledger_path do
    Path.join(temporary_root(), "runs.dets")
  end

  defp temporary_root do
    assert {:ok, tmp_root} = SymphonyElixir.PathSafety.canonicalize(System.tmp_dir!())

    root =
      Path.join(
        tmp_root,
        "symphony-run-ledger-api-coverage-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp anchor_marker_path(anchor_directory) do
    [marker] = Path.wildcard(Path.join(anchor_directory, "*.json"))
    marker
  end
end
