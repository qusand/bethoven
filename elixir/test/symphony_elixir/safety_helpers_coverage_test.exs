defmodule SymphonyElixir.SafetyHelpersCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config.Schema, IssueBudget, PathSafety, SensitiveData}

  test "issue budgets reject malformed limits and normalize non-map policies" do
    refute IssueBudget.reached?(1, 0)
    refute IssueBudget.reached?("not-a-number", 1)

    assert IssueBudget.merge_stricter(:missing, %{max_tokens: 20}) == %{
             max_sessions: nil,
             max_turns: nil,
             max_tokens: 20,
             max_wall_time_ms: nil,
             max_consecutive_failures: nil
           }

    assert IssueBudget.merge_stricter(%{max_turns: 3}, :missing).max_turns == 3
    assert IssueBudget.merge_stricter(:missing, :missing).max_tokens == nil
  end

  test "issue wall-time budgets accept DateTimes and fail closed for invalid timestamps" do
    now = DateTime.utc_now()
    started = DateTime.add(now, -2, :second)
    budget = %{max_wall_time_ms: 1_000}

    assert IssueBudget.exhaustion_reason(%{first_started_at: started}, budget, now) ==
             :max_wall_time_ms

    assert IssueBudget.exhaustion_reason(%{first_started_at: nil}, budget, now) == nil
    assert IssueBudget.exhaustion_reason(%{first_started_at: "invalid"}, budget, now) == nil
    assert IssueBudget.exhaustion_reason(%{first_started_at: 123}, budget, now) == nil
  end

  test "sensitive-data redaction preserves calendar values and ordinary non-string keys" do
    date = ~D[2026-07-20]
    time = ~T[20:00:00]
    naive = ~N[2026-07-20 20:00:00]

    assert SensitiveData.redact(date) == date
    assert SensitiveData.redact(time) == time
    assert SensitiveData.redact(naive) == naive
    assert SensitiveData.redact(%{42 => "ordinary"}) == %{42 => "ordinary"}
  end

  test "path safety surfaces lstat errors and bounds symlink traversal" do
    assert {:error, {_candidate, :badarg}} = PathSafety.ensure_no_symlink_segments(<<0>>)

    root = unique_tmp_dir("symlink-chain")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    target = Path.join(root, "target")
    File.write!(target, "target")

    Enum.each(0..40, fn index ->
      source = Path.join(root, "link-#{index}")
      destination = if index == 40, do: target, else: Path.join(root, "link-#{index + 1}")
      File.ln_s!(destination, source)
    end)

    assert {:error, {:path_canonicalize_failed, _path, :too_many_symlink_hops}} =
             PathSafety.canonicalize(Path.join(root, "link-0"))
  end

  test "state-root resolution rejects missing environment values and invalid root types" do
    env_name = "BETHOVEN_MISSING_STATE_ROOT_#{System.unique_integer([:positive])}"
    System.delete_env(env_name)

    missing_env_settings = %Schema{state: %Schema.State{root: "$#{env_name}"}}

    assert {:error, {:invalid_state_root, "$" <> ^env_name}} =
             Schema.with_state_root(missing_env_settings, "/tmp/WORKFLOW.md")

    invalid_type_settings = %Schema{state: %Schema.State{root: 123}}

    assert {:error, {:invalid_state_root, 123}} =
             Schema.with_state_root(invalid_type_settings, "/tmp/WORKFLOW.md")
  end

  test "relative state roots are anchored to the workflow directory" do
    root = unique_tmp_dir("relative-state-root")
    workflow_directory = Path.join(root, "workflow")
    workflow_path = Path.join(workflow_directory, "WORKFLOW.md")
    File.mkdir_p!(workflow_directory)
    File.write!(workflow_path, "---\n---\n")
    on_exit(fn -> File.rm_rf(root) end)

    settings = %Schema{state: %Schema.State{root: "state"}}

    assert {:ok, %{state: %{root: resolved_root}}} =
             Schema.with_state_root(settings, workflow_path)

    assert {:ok, expected_root} =
             PathSafety.canonical_local_path(Path.join(workflow_directory, "state"))

    assert resolved_root == expected_root
  end

  test "default state-root resolution propagates an invalid workflow identity" do
    root = unique_tmp_dir("workflow-symlink-chain")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    target = Path.join(root, "WORKFLOW.md")
    File.write!(target, "workflow")

    Enum.each(0..40, fn index ->
      source = Path.join(root, "workflow-link-#{index}")

      destination =
        if index == 40, do: target, else: Path.join(root, "workflow-link-#{index + 1}")

      File.ln_s!(destination, source)
    end)

    settings = %Schema{state: %Schema.State{root: nil}}

    assert {:error, {:invalid_state_root, {:invalid_workflow_identity, canonicalize_error}}} =
             Schema.with_state_root(settings, Path.join(root, "workflow-link-0"))

    assert {:path_canonicalize_failed, _path, :too_many_symlink_hops} = canonicalize_error
  end

  defp unique_tmp_dir(suffix) do
    Path.join(
      System.tmp_dir!(),
      "bethoven-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
