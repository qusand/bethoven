defmodule SymphonyElixir.RunLedgerProjectionCoverageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunLedger

  @dispatch_time "2026-07-20T12:00:00.000000Z"
  @started_time "2026-07-20T12:01:00.000000Z"

  test "normalizes public event boundaries and rejects invalid field shapes" do
    assert {:error, {:ledger_event_too_large, 1}} =
             RunLedger.normalize_event(dispatch_input(), max_event_bytes: 1)

    assert {:error, :invalid_ledger_options} =
             RunLedger.normalize_event(dispatch_input(), [:not_a_keyword])

    assert {:error, :invalid_ledger_options} =
             RunLedger.normalize_event(dispatch_input(), [{:max_event_bytes, 2}, {:max_event_bytes, 3}])

    assert {:error, :invalid_ledger_event_shape} =
             RunLedger.normalize_event(Map.put(dispatch_input(), 1, "not-a-key"), [])

    assert {:error, {:invalid_ledger_event, :event_id}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :event_id, 1), [])

    assert {:error, {:invalid_ledger_event, :issue_identifier}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :issue_identifier, 1), [])

    assert {:ok, blank_identifier, _opts} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :issue_identifier, "   "), [])

    assert blank_identifier["issue_identifier"] == nil

    assert {:error, {:invalid_ledger_event, :issue_identifier}} =
             RunLedger.normalize_event(
               Map.put(dispatch_input(), :issue_identifier, String.duplicate("x", 4_097)),
               []
             )

    assert {:error, {:invalid_ledger_event, :type}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :type, 1), [])

    assert {:error, {:invalid_ledger_timestamp, "not-a-timestamp"}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :recorded_at, "not-a-timestamp"), [])

    assert {:error, {:invalid_ledger_timestamp, :invalid}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :recorded_at, 1), [])

    assert {:error, {:invalid_ledger_event, :data}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :data, :not_a_map), [])

    assert {:error, {:invalid_ledger_event_data, "run_id"}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :data, %{run_id: 1}), [])

    assert {:error, {:invalid_ledger_event_data, "worker_host"}} =
             RunLedger.normalize_event(
               event_input(:worker_started, %{run_id: "run-1", worker_host: 1}),
               []
             )

    assert {:error, {:invalid_ledger_event_data, "turn_number"}} =
             RunLedger.normalize_event(
               event_input(:turn_reserved, %{run_id: "run-1", turn_number: 0}),
               []
             )

    assert {:error, {:invalid_ledger_event_data, :budget}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :data, %{run_id: "run-1", budget: :invalid}), [])

    assert {:error, {:invalid_ledger_event_data, "retry_attempt"}} =
             RunLedger.normalize_event(Map.put(dispatch_input(), :data, %{run_id: "run-1", retry_attempt: -1}), [])

    assert {:error, {:invalid_ledger_event_data, "input_tokens"}} =
             RunLedger.normalize_event(
               event_input(:usage, %{run_id: "run-1", input_tokens: -1, output_tokens: 0, total_tokens: 0}),
               []
             )

    assert {:error, {:invalid_ledger_event_data, "retry_due_at"}} =
             RunLedger.normalize_event(
               event_input(:failure, %{run_id: "run-1", retry_due_at: "not-a-timestamp"}),
               []
             )

    assert {:error, {:invalid_ledger_event_data, :error}} =
             RunLedger.normalize_event(event_input(:failure, %{run_id: "run-1", error: 1}), [])

    assert {:error, {:invalid_ledger_event_data, :usage_reconciliation}} =
             RunLedger.normalize_event(event_input(:failure, %{run_id: "run-1", usage_reconciliation: 1}), [])

    assert {:error, {:invalid_ledger_event_data, :restart_recovery}} =
             RunLedger.normalize_event(event_input(:failure, %{run_id: "run-1", restart_recovery: false}), [])

    assert {:ok, _event, _opts} = RunLedger.normalize_event(event_input(:note, %{}), [])

    assert {:error, {:invalid_ledger_event_data, :detail}} =
             RunLedger.normalize_event(event_input(:note, %{detail: 1}), [])

    assert {:error, {:invalid_ledger_event_data, :unsupported_key}} =
             RunLedger.normalize_event(event_input(:note, %{unexpected: true}), [])

    assert {:ok, note, _opts} =
             RunLedger.normalize_event(event_input(:note, %{detail: String.duplicate("x", 513)}), [])

    assert note["data"]["detail"] =~ "[truncated]"

    assert {:error, {:invalid_ledger_event_data, "reason"}} =
             RunLedger.normalize_event(event_input(:terminal, %{reason: "  "}), [])

    assert {:error, {:invalid_ledger_event_data, "reason"}} =
             RunLedger.normalize_event(event_input(:terminal, %{reason: 1}), [])

    assert {:error, {:invalid_ledger_event_data, :unsupported_key}} =
             RunLedger.normalize_event(
               Map.put(dispatch_input(), :data, %{run_id: "run-1", unexpected: [%{nested: true}]}),
               []
             )
  end

  test "normalizes complete optional data for every lifecycle payload family" do
    assert {:ok, dispatch, _opts} =
             RunLedger.normalize_event(
               event_input(
                 :dispatch,
                 %{
                   run_id: "run-optional",
                   worker_host: nil,
                   workspace_path: "/workspace",
                   budget: %{max_sessions: 1, max_tokens: nil},
                   retry_attempt: 1
                 },
                 %{issue_identifier: nil, recorded_at: nil}
               ),
               []
             )

    assert dispatch["issue_identifier"] == nil
    assert is_binary(dispatch["recorded_at"])

    assert {:ok, _event, _opts} =
             RunLedger.normalize_event(event_input(:worker_started, %{run_id: "run-optional"}), [])

    assert {:ok, _event, _opts} =
             RunLedger.normalize_event(
               event_input(
                 :turn_reserved,
                 %{run_id: "run-optional", thread_id: "thread-1", turn_number: 1}
               ),
               []
             )

    assert {:ok, _event, _opts} =
             RunLedger.normalize_event(
               event_input(:turn_started, %{run_id: "run-optional", session_id: "session-1", thread_id: "thread-1"}),
               []
             )

    assert {:ok, _event, _opts} =
             RunLedger.normalize_event(
               event_input(:usage, %{run_id: "run-optional", input_tokens: 2, output_tokens: 3, total_tokens: 5}),
               []
             )

    assert {:ok, _event, _opts} =
             RunLedger.normalize_event(
               event_input(
                 :runtime_info,
                 %{
                   run_id: "run-optional",
                   worker_host: "worker-a",
                   workspace_path: "/workspace",
                   session_id: "session-1",
                   thread_id: "thread-1"
                 }
               ),
               []
             )

    completed_data = %{
      run_id: "run-optional",
      worker_host: "worker-a",
      workspace_path: "/workspace",
      session_id: "session-1",
      thread_id: "thread-1",
      retry_attempt: 1,
      retry_due_at: @started_time,
      error: "worker output retained safely",
      usage_reconciliation: "unreconciled"
    }

    assert {:ok, _event, _opts} = RunLedger.normalize_event(event_input(:worker_completed, completed_data), [])

    assert {:ok, _event, _opts} =
             RunLedger.normalize_event(
               event_input(:failure, %{run_id: "run-optional", error: nil, restart_recovery: true}),
               []
             )

    assert {:ok, _event, _opts} =
             RunLedger.normalize_event(event_input(:terminal, %{reason: "finished normally"}), [])
  end

  test "enforces causally valid public lifecycle transitions" do
    dispatch = normalized_event!("event-dispatch", :dispatch, %{run_id: "run-1"})
    issue = RunLedger.empty_issue("issue-1", "ISSUE-1")
    assert {:ok, dispatched} = RunLedger.apply_event(issue, dispatch, 3)

    assert {:error, {:invalid_ledger_transition, "dispatching", "dispatch"}} =
             RunLedger.apply_event(dispatched, dispatch, 3)

    budget_exhausted = normalized_event!("event-budget", :budget_exhausted, %{})

    assert {:error, {:invalid_ledger_transition, "unknown", "budget_exhausted"}} =
             RunLedger.apply_event(issue, budget_exhausted, 3)
  end

  test "applies every legal lifecycle state and rejects stale or premature events" do
    issue = RunLedger.empty_issue("issue-lifecycle", "LIFECYCLE-1")
    dispatch = normalized_event!("lifecycle-dispatch", :dispatch, %{run_id: "run-lifecycle"})
    assert {:ok, dispatching} = RunLedger.apply_event(issue, dispatch, 5)

    premature_turn =
      normalized_event!(
        "lifecycle-premature-turn",
        :turn_started,
        %{run_id: "run-lifecycle", session_id: "session-1"}
      )

    assert {:error, {:invalid_ledger_transition, "dispatching", "turn_started"}} =
             RunLedger.apply_event(dispatching, premature_turn, 5)

    started = normalized_event!("lifecycle-started", :worker_started, %{run_id: "run-lifecycle"})
    assert {:ok, running} = RunLedger.apply_event(dispatching, started, 5)

    stale_usage =
      normalized_event!(
        "lifecycle-stale-usage",
        :usage,
        %{run_id: "old-run", input_tokens: 0, output_tokens: 0, total_tokens: 0}
      )

    assert {:error, {:stale_or_invalid_run, "old-run"}} = RunLedger.apply_event(running, stale_usage, 5)

    runtime =
      normalized_event!(
        "lifecycle-runtime",
        :runtime_info,
        %{run_id: "run-lifecycle", worker_host: "worker-a", workspace_path: "/workspace"}
      )

    assert {:ok, running} = RunLedger.apply_event(running, runtime, 5)

    turn =
      normalized_event!(
        "lifecycle-turn",
        :turn_started,
        %{run_id: "run-lifecycle", session_id: "session-1", thread_id: "thread-1"}
      )

    assert {:ok, running} = RunLedger.apply_event(running, turn, 5)

    usage =
      normalized_event!(
        "lifecycle-usage",
        :usage,
        %{run_id: "run-lifecycle", input_tokens: 2, output_tokens: 3, total_tokens: 5}
      )

    assert {:ok, running} = RunLedger.apply_event(running, usage, 5)

    budget = normalized_event!("lifecycle-budget", :budget_exhausted, %{run_id: "run-lifecycle"})
    assert {:ok, %{status: "budget_exhausted"}} = RunLedger.apply_event(running, budget, 5)

    completed = normalized_event!("lifecycle-completed", :worker_completed, %{run_id: "run-lifecycle"})
    assert {:ok, continuing} = RunLedger.apply_event(running, completed, 5)

    continuation =
      normalized_event!("lifecycle-continuation", :continuation_scheduled, %{run_id: "run-lifecycle"})

    assert {:ok, retrying} = RunLedger.apply_event(continuing, continuation, 5)

    blocked = normalized_event!("lifecycle-blocked", :blocked, %{run_id: "run-lifecycle"})
    assert {:ok, blocked} = RunLedger.apply_event(retrying, blocked, 5)

    terminal = normalized_event!("lifecycle-terminal", :terminal, %{run_id: "run-lifecycle", reason: "finished normally"})
    assert {:ok, terminal} = RunLedger.apply_event(blocked, terminal, 5)

    released = normalized_event!("lifecycle-released", :released, %{})
    assert {:ok, released} = RunLedger.apply_event(terminal, released, 5)

    abandoned = normalized_event!("lifecycle-abandoned", :abandoned, %{})
    assert {:ok, abandoned} = RunLedger.apply_event(released, abandoned, 5)

    note = normalized_event!("lifecycle-note", :note, %{detail: "audit note"})
    assert {:ok, %{status: "abandoned"}} = RunLedger.apply_event(abandoned, note, 5)

    retry_dispatch = normalized_event!("retry-dispatch", :dispatch, %{run_id: "run-retry"})
    assert {:ok, retry_dispatching} = RunLedger.apply_event(issue, retry_dispatch, 5)

    stale_retry = normalized_event!("retry-stale", :retry_scheduled, %{run_id: "old-run"})
    assert {:error, {:stale_or_invalid_run, "old-run"}} = RunLedger.apply_event(retry_dispatching, stale_retry, 5)

    premature_retry = normalized_event!("retry-premature", :retry_scheduled, %{run_id: "run-retry"})

    assert {:error, {:invalid_ledger_transition, "dispatching", "retry_scheduled"}} =
             RunLedger.apply_event(retry_dispatching, premature_retry, 5)

    retry_started = normalized_event!("retry-started", :worker_started, %{run_id: "run-retry"})
    assert {:ok, retry_running} = RunLedger.apply_event(retry_dispatching, retry_started, 5)

    failure = normalized_event!("retry-failure", :failure, %{run_id: "run-retry"})
    assert {:ok, failing} = RunLedger.apply_event(retry_running, failure, 5)

    retry = normalized_event!("retry-scheduled", :retry_scheduled, %{run_id: "run-retry"})
    assert {:ok, %{status: "retrying"}} = RunLedger.apply_event(failing, retry, 5)

    recovery_dispatch = normalized_event!("recovery-dispatch", :dispatch, %{run_id: "run-recovery"})
    assert {:ok, recovery_dispatching} = RunLedger.apply_event(issue, recovery_dispatch, 5)

    restart_retry =
      normalized_event!(
        "recovery-retry",
        :retry_scheduled,
        %{run_id: "run-recovery", restart_recovery: true}
      )

    assert {:ok, %{status: "retrying"}} = RunLedger.apply_event(recovery_dispatching, restart_retry, 5)
  end

  test "accepts complete persisted commit checkpoint identity and intent records" do
    %{commit: commit, checkpoint: checkpoint, event: event, intent: intent, issue_id: issue_id} = valid_records!()

    assert {:ok, normalized_commit} = RunLedger.validate_persisted_commit(commit)
    assert normalized_commit == commit

    assert {:ok, ^checkpoint} = RunLedger.validate_persisted_checkpoint(checkpoint, issue_id)

    identity = %{"schema_version" => RunLedger.schema_version(), "identity" => event["identity"]}
    assert {:ok, ^identity} = RunLedger.validate_persisted_event_identity(identity, event["event_id"])

    assert {:ok, ^intent} = RunLedger.validate_persisted_intent(intent, event["event_id"])

    %{event: started, intent: started_intent} = valid_started_intent!()
    assert {:ok, ^started_intent} = RunLedger.validate_persisted_intent(started_intent, started["event_id"])
  end

  test "rejects malformed persisted commit identity checkpoint and intent records" do
    %{commit: commit, checkpoint: checkpoint, event: event, intent: intent, issue_id: issue_id} = valid_records!()

    assert {:error, :invalid_commit} = RunLedger.validate_persisted_commit(:not_a_commit)
    assert {:error, :invalid_commit} = RunLedger.validate_persisted_commit(Map.put(commit, "extra", true))
    assert {:error, :invalid_commit} = RunLedger.validate_persisted_commit(Map.put(commit, "event_id", "other-event"))

    assert {:error, {:invalid_ledger_timestamp, "not-a-timestamp"}} =
             RunLedger.validate_persisted_commit(put_in(commit, ["event", "recorded_at"], "not-a-timestamp"))

    assert {:error, :invalid_persisted_event} =
             RunLedger.validate_persisted_commit(put_in(commit, ["event", "identity"], %{}))

    assert {:error, :invalid_persisted_event} =
             RunLedger.validate_persisted_commit(update_in(commit, ["event"], &Map.put(&1, "extra", true)))

    assert {:error, :invalid_persisted_event} =
             RunLedger.validate_persisted_commit(Map.put(commit, "event", :not_a_map))

    assert {:error, :invalid_checkpoint} = RunLedger.validate_persisted_checkpoint(:not_a_checkpoint, issue_id)
    assert {:error, :invalid_checkpoint} = RunLedger.validate_persisted_checkpoint(checkpoint, "other-issue")

    assert {:error, :invalid_projection} =
             RunLedger.validate_persisted_checkpoint(Map.put(checkpoint, "projection", %{}), issue_id)

    identity = %{"schema_version" => RunLedger.schema_version(), "identity" => event["identity"]}
    assert {:error, :invalid_event_identity} = RunLedger.validate_persisted_event_identity(identity, "other-event")
    assert {:error, :invalid_event_identity} = RunLedger.validate_persisted_event_identity(:not_an_identity, event["event_id"])

    assert {:error, {:invalid_ledger_event, :event_id}} =
             RunLedger.validate_persisted_event_identity(%{"schema_version" => RunLedger.schema_version(), "identity" => %{}}, event["event_id"])

    %{event: started, intent: started_intent} = valid_started_intent!()

    assert {:error, :invalid_intent} =
             RunLedger.validate_persisted_intent(
               Map.put(started_intent, "base_last_event_id", nil),
               started["event_id"]
             )

    assert {:error, :invalid_intent} =
             RunLedger.validate_persisted_intent(
               Map.put(intent, "base_last_event_id", "unexpected-prior-event"),
               event["event_id"]
             )

    assert {:error, :invalid_intent} = RunLedger.validate_persisted_intent(:not_an_intent, event["event_id"])

    assert {:error, {:invalid_ledger_timestamp, "not-a-timestamp"}} =
             RunLedger.validate_persisted_intent(
               put_in(intent, ["event", "recorded_at"], "not-a-timestamp"),
               event["event_id"]
             )
  end

  test "rejects each invalid durable projection invariant" do
    %{checkpoint: checkpoint, issue_id: issue_id} = valid_records!()
    projection = checkpoint["projection"]

    retained_projection = %{
      projection
      | version: 4,
        event_count: 4,
        recent_event_ids: ["event-a", "event-b", "event-c", "event-d"]
    }

    assert {:error, :invalid_projection} = checkpoint_error(checkpoint, issue_id, retained_projection, 3)

    assert {:error, :invalid_projection} =
             checkpoint_error(checkpoint, issue_id, %{projection | last_event_id: 1})

    assert {:error, :invalid_projection} =
             checkpoint_error(checkpoint, issue_id, %{projection | run_id: 1})

    assert {:error, :invalid_projection} =
             checkpoint_error(checkpoint, issue_id, %{projection | prompt_bytes: -1})

    assert {:ok, _checkpoint} =
             checkpoint_error(checkpoint, issue_id, %{projection | prompt_bytes: 0})

    assert {:ok, _checkpoint} =
             checkpoint_error(checkpoint, issue_id, %{projection | budget: %{"max_sessions" => 1, "max_tokens" => nil}})

    assert {:error, :invalid_projection} =
             checkpoint_error(checkpoint, issue_id, %{projection | usage_reconciliation: "unsupported"})

    assert {:error, :invalid_projection} =
             checkpoint_error(checkpoint, issue_id, %{projection | usage_reconciliation: 1})

    assert {:error, :invalid_projection} =
             checkpoint_error(checkpoint, issue_id, %{projection | last_started_at: 1})

    assert {:error, :invalid_projection} =
             checkpoint_error(checkpoint, issue_id, %{projection | budget: :unsupported})

    assert {:error, :invalid_projection} =
             RunLedger.validate_persisted_checkpoint(Map.put(checkpoint, "projection", :not_a_map), issue_id)
  end

  defp dispatch_input do
    event_input(:dispatch, %{run_id: "run-1"})
  end

  defp event_input(type, data, overrides \\ %{}) do
    %{
      event_id: "event-1",
      issue_id: "issue-1",
      issue_identifier: "ISSUE-1",
      type: type,
      recorded_at: @dispatch_time,
      data: data
    }
    |> Map.merge(overrides)
  end

  defp normalized_event!(event_id, type, data, overrides \\ %{}) do
    input = event_input(type, data, Map.put(overrides, :event_id, event_id))
    assert {:ok, event, _opts} = RunLedger.normalize_event(input, [])
    event
  end

  defp valid_records! do
    event = normalized_event!("event-dispatch", :dispatch, %{run_id: "run-1"})
    issue = RunLedger.empty_issue("issue-1", "ISSUE-1")
    assert {:ok, projection} = RunLedger.apply_event(issue, event, 3)

    commit = %{
      "schema_version" => RunLedger.schema_version(),
      "event_id" => event["event_id"],
      "event" => event,
      "projection" => projection,
      "sequence" => projection.version,
      "retention" => 3
    }

    checkpoint = %{
      "schema_version" => RunLedger.schema_version(),
      "projection" => projection,
      "retention" => 3
    }

    intent = %{
      "schema_version" => RunLedger.schema_version(),
      "identity" => event["identity"],
      "event" => event,
      "base_version" => 0,
      "base_last_event_id" => nil,
      "projection" => projection,
      "retention" => 3
    }

    %{commit: commit, checkpoint: checkpoint, event: event, intent: intent, issue_id: "issue-1"}
  end

  defp valid_started_intent! do
    %{event: dispatch, checkpoint: checkpoint} = valid_records!()

    started =
      normalized_event!(
        "event-started",
        :worker_started,
        %{run_id: "run-1"},
        %{recorded_at: @started_time}
      )

    assert {:ok, projection} = RunLedger.apply_event(checkpoint["projection"], started, 3)

    intent = %{
      "schema_version" => RunLedger.schema_version(),
      "identity" => started["identity"],
      "event" => started,
      "base_version" => checkpoint["projection"].version,
      "base_last_event_id" => dispatch["event_id"],
      "projection" => projection,
      "retention" => 3
    }

    %{event: started, intent: intent}
  end

  defp checkpoint_error(checkpoint, issue_id, projection, retention \\ nil) do
    checkpoint =
      checkpoint
      |> Map.put("projection", projection)
      |> maybe_put_retention(retention)

    RunLedger.validate_persisted_checkpoint(checkpoint, issue_id)
  end

  defp maybe_put_retention(checkpoint, nil), do: checkpoint
  defp maybe_put_retention(checkpoint, retention), do: Map.put(checkpoint, "retention", retention)
end
