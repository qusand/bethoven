defmodule SymphonyElixir.SafetyHelpersCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config.Schema, IssueBudget, PathSafety, SensitiveData}

  defmodule SensitiveFixture do
    defstruct [:name, :api_key, :nested]
  end

  defmodule SecretDefaultFixture do
    defstruct api_key: "default-secret", name: nil
  end

  defmodule RaisingStructFixture do
    def __struct__, do: raise("forged struct module")
  end

  defmodule ThrowingStructFixture do
    def __struct__, do: throw("forged struct module")
  end

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

  test "sensitive-data redaction preserves struct types and bounds untrusted collections" do
    fixture = %SensitiveFixture{
      name: "fixture",
      api_key: "struct-secret",
      nested: %{password: "nested-secret"}
    }

    assert %SensitiveFixture{
             name: "fixture",
             api_key: "[REDACTED]",
             nested: %{password: "[REDACTED]"}
           } = SensitiveData.redact(fixture)

    assert map_size(SensitiveData.redact(Map.new(1..101, &{&1, &1}))) == 100
    assert length(SensitiveData.redact(Enum.to_list(1..101))) == 100
    assert tuple_size(SensitiveData.redact(List.to_tuple(Enum.to_list(1..10_000)))) == 100
    assert String.length(SensitiveData.redact(String.duplicate("x", 4_097))) == 4_096

    deep_value = Enum.reduce(1..10, "unbounded-tail", fn _index, nested -> [nested] end)
    inspected = deep_value |> SensitiveData.redact() |> inspect()
    assert inspected =~ "[TRUNCATED]"
    refute inspected =~ "unbounded-tail"
  end

  test "sensitive-data redaction treats forged and incomplete structs as untrusted maps" do
    forged_values = [
      %{__struct__: :not_a_module, api_key: "bogus-secret"},
      %{__struct__: String, password: "module-secret"},
      %{__struct__: RaisingStructFixture, token: "raising-secret"},
      %{__struct__: ThrowingStructFixture, secret: "throwing-secret"},
      %{__struct__: SecretDefaultFixture, name: "incomplete"},
      %{__struct__: DateTime, password: "calendar-spoof-secret"}
    ]

    inspected = forged_values |> SensitiveData.redact() |> inspect()

    for secret <- [
          "bogus-secret",
          "module-secret",
          "raising-secret",
          "throwing-secret",
          "default-secret",
          "calendar-spoof-secret"
        ] do
      refute inspected =~ secret
    end

    assert inspected =~ "[REDACTED]"
  end

  test "sensitive-data redaction sanitizes complete calendar structs and improper lists" do
    hostile_calendar =
      DateTime.utc_now()
      |> Map.put(:time_zone, "password=calendar-secret")
      |> Map.put(:zone_abbr, "Bearer calendar-token")

    calendar_inspected = SensitiveData.safe_inspect(hostile_calendar)
    refute calendar_inspected =~ "calendar-secret"
    refute calendar_inspected =~ "calendar-token"
    assert calendar_inspected =~ "[REDACTED]"

    improper = [%{password: "improper-secret"} | "token=tail-secret"]
    improper_inspected = SensitiveData.safe_inspect(improper)
    refute improper_inspected =~ "improper-secret"
    refute improper_inspected =~ "tail-secret"
    assert improper_inspected =~ "[REDACTED]"
    assert SensitiveData.redact([1 | 2]) == [1, 2]
  end

  test "sensitive-data redaction bounds and sanitizes untrusted map keys" do
    huge_key = String.duplicate("x", 8_192)
    invalid_key = <<255, 0, 1>>

    redacted =
      SensitiveData.redact(%{
        huge_key => "huge-key-value-secret",
        invalid_key => "invalid-key-value-secret",
        "password=inline-key-secret" => "inline-value-secret",
        {:authorization, "Bearer tuple-key-secret"} => "ordinary"
      })

    inspected = inspect(redacted, printable_limit: 20_000)

    refute inspected =~ huge_key
    refute inspected =~ "huge-key-value-secret"
    refute inspected =~ "invalid-key-value-secret"
    refute inspected =~ "inline-key-secret"
    refute inspected =~ "inline-value-secret"
    refute inspected =~ "tuple-key-secret"
    assert inspected =~ "[TRUNCATED]"
    assert inspected =~ "[REDACTED]"
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
