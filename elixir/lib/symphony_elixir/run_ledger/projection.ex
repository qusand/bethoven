defmodule SymphonyElixir.RunLedger.Projection do
  @moduledoc false

  alias SymphonyElixir.SensitiveData

  @schema_version 4
  @default_max_event_bytes 65_536
  @default_max_events_per_issue 200
  @max_string_bytes 4_096
  @max_error_bytes 512

  @event_types MapSet.new([
                 "dispatch",
                 "worker_started",
                 "turn_reserved",
                 "turn_started",
                 "usage",
                 "runtime_info",
                 "worker_completed",
                 "failure",
                 "retry_scheduled",
                 "continuation_scheduled",
                 "blocked",
                 "budget_exhausted",
                 "terminal",
                 "released",
                 "abandoned",
                 "note"
               ])

  @budget_keys MapSet.new([
                 "max_sessions",
                 "max_turns",
                 "max_tokens",
                 "max_wall_time_ms",
                 "max_consecutive_failures"
               ])

  @usage_reconciliations MapSet.new(["unreconciled"])

  @public_event_keys [
    "event_id",
    "issue_id",
    "issue_identifier",
    "type",
    "recorded_at",
    "data"
  ]

  @persisted_event_keys @public_event_keys ++ ["schema_version", "identity"]

  @commit_keys MapSet.new([
                 "schema_version",
                 "event_id",
                 "event",
                 "projection",
                 "sequence",
                 "retention"
               ])

  @checkpoint_keys MapSet.new(["schema_version", "projection", "retention"])
  @event_identity_keys MapSet.new(["schema_version", "identity"])

  @intent_keys MapSet.new([
                 "schema_version",
                 "identity",
                 "event",
                 "base_version",
                 "base_last_event_id",
                 "projection",
                 "retention"
               ])

  @projection_keys MapSet.new([
                     :issue_id,
                     :issue_identifier,
                     :run_id,
                     :status,
                     :version,
                     :session_count,
                     :turn_count,
                     :input_tokens,
                     :output_tokens,
                     :total_tokens,
                     :consecutive_failures,
                     :first_started_at,
                     :last_started_at,
                     :last_updated_at,
                     :worker_host,
                     :workspace_path,
                     :thread_id,
                     :session_id,
                     :prompt_hash,
                     :prompt_bytes,
                     :budget,
                     :retry_attempt,
                     :retry_due_at,
                     :terminal_reason,
                     :last_error,
                     :usage_reconciliation,
                     :event_count,
                     :last_event_id,
                     :recent_event_ids
                   ])

  @issue_statuses MapSet.new([
                    "unknown",
                    "dispatching",
                    "running",
                    "continuing",
                    "failing",
                    "retrying",
                    "blocked",
                    "budget_exhausted",
                    "terminal",
                    "released",
                    "abandoned"
                  ])

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

  @doc false
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc false
  @spec normalize_event(map(), keyword()) ::
          {:ok, map(), map()} | {:error, term()}
  def normalize_event(event, opts) when is_map(event) and is_list(opts) do
    with {:ok, normalized_opts} <- normalize_options(opts),
         :ok <- validate_map_keys(event, @public_event_keys),
         {:ok, event_id} <- required_string(event, :event_id),
         {:ok, issue_id} <- required_string(event, :issue_id),
         {:ok, issue_identifier} <- optional_string(event, :issue_identifier),
         {:ok, type} <- required_type(event),
         {:ok, recorded_at, identity_recorded_at} <- normalize_recorded_at(value(event, :recorded_at)),
         {:ok, data} <- normalize_data(type, value(event, :data, %{})) do
      normalized_event = %{
        "schema_version" => @schema_version,
        "event_id" => event_id,
        "issue_id" => issue_id,
        "issue_identifier" => issue_identifier,
        "type" => type,
        "recorded_at" => recorded_at,
        "data" => data
      }

      identity =
        normalized_event
        |> Map.put("recorded_at", identity_recorded_at)
        |> Map.delete("schema_version")

      normalized_event = Map.put(normalized_event, "identity", identity)

      if byte_size(:erlang.term_to_binary(normalized_event)) <= normalized_opts.max_event_bytes do
        {:ok, normalized_event, normalized_opts}
      else
        {:error, {:ledger_event_too_large, normalized_opts.max_event_bytes}}
      end
    end
  end

  @doc false
  @spec validate_persisted_commit(term()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_commit(
        %{
          "schema_version" => @schema_version,
          "event" => event,
          "projection" => projection,
          "sequence" => sequence,
          "retention" => retention
        } = commit
      )
      when is_integer(sequence) and sequence > 0 and is_integer(retention) and retention > 0 do
    with :ok <- validate_persisted_commit_shape(commit),
         {:ok, normalized_event, _opts} <- normalize_persisted_event(event),
         true <- normalized_event["identity"] == Map.get(event, "identity"),
         {:ok, normalized_projection} <- validate_projection(projection, retention),
         true <- normalized_event["event_id"] == Map.get(commit, "event_id"),
         true <- normalized_projection.issue_id == normalized_event["issue_id"],
         true <- normalized_projection.version == sequence,
         true <- normalized_projection.last_event_id == normalized_event["event_id"],
         true <- normalized_projection.last_updated_at == normalized_event["recorded_at"] do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "event_id" => normalized_event["event_id"],
         "event" => normalized_event,
         "projection" => normalized_projection,
         "sequence" => sequence,
         "retention" => retention
       }}
    else
      false -> {:error, :invalid_commit}
      {:error, _reason} = error -> error
    end
  end

  def validate_persisted_commit(_commit), do: {:error, :invalid_commit}

  @doc false
  @spec validate_persisted_checkpoint(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_checkpoint(
        %{
          "schema_version" => @schema_version,
          "projection" => projection,
          "retention" => retention
        } = checkpoint,
        issue_id
      )
      when is_binary(issue_id) and is_integer(retention) and retention > 0 do
    with true <- Enum.all?(Map.keys(checkpoint), &is_binary/1),
         true <- MapSet.equal?(MapSet.new(Map.keys(checkpoint)), @checkpoint_keys),
         {:ok, normalized_projection} <- validate_projection(projection, retention),
         true <- normalized_projection.issue_id == issue_id,
         true <- normalized_projection.version > 0 do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "projection" => normalized_projection,
         "retention" => retention
       }}
    else
      false -> {:error, :invalid_checkpoint}
      {:error, _reason} = error -> error
    end
  end

  def validate_persisted_checkpoint(_checkpoint, _issue_id), do: {:error, :invalid_checkpoint}

  @doc false
  @spec validate_persisted_event_identity(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_event_identity(
        %{"schema_version" => @schema_version, "identity" => identity} = record,
        event_id
      )
      when is_binary(event_id) do
    with true <- Enum.all?(Map.keys(record), &is_binary/1),
         true <- MapSet.equal?(MapSet.new(Map.keys(record)), @event_identity_keys),
         {:ok, normalized_event, _opts} <- normalize_event(identity, []),
         true <- normalized_event["event_id"] == event_id,
         true <- normalized_event["identity"] == identity do
      {:ok, %{"schema_version" => @schema_version, "identity" => identity}}
    else
      false -> {:error, :invalid_event_identity}
      {:error, _reason} = error -> error
    end
  end

  def validate_persisted_event_identity(_record, _event_id), do: {:error, :invalid_event_identity}

  @doc false
  @spec validate_persisted_intent(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate_persisted_intent(
        %{
          "schema_version" => @schema_version,
          "identity" => identity,
          "event" => event,
          "base_version" => base_version,
          "base_last_event_id" => base_last_event_id,
          "projection" => projection,
          "retention" => retention
        } = intent,
        event_id
      )
      when is_binary(event_id) and is_integer(base_version) and base_version >= 0 and
             is_integer(retention) and retention > 0 do
    with true <- Enum.all?(Map.keys(intent), &is_binary/1),
         true <- MapSet.equal?(MapSet.new(Map.keys(intent)), @intent_keys),
         {:ok, normalized_event, _opts} <- normalize_persisted_event(event),
         true <- normalized_event["event_id"] == event_id,
         true <- normalized_event["identity"] == identity,
         true <- valid_base_last_event_id?(base_version, base_last_event_id),
         {:ok, normalized_projection} <- validate_projection(projection, retention),
         true <- normalized_projection.issue_id == normalized_event["issue_id"],
         true <- normalized_projection.version == base_version + 1,
         true <- normalized_projection.last_event_id == event_id do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "identity" => identity,
         "event" => normalized_event,
         "base_version" => base_version,
         "base_last_event_id" => base_last_event_id,
         "projection" => normalized_projection,
         "retention" => retention
       }}
    else
      false -> {:error, :invalid_intent}
      {:error, _reason} = error -> error
    end
  end

  def validate_persisted_intent(_intent, _event_id), do: {:error, :invalid_intent}

  @doc false
  @spec empty_issue(String.t(), String.t() | nil) :: issue_snapshot()
  def empty_issue(issue_id, issue_identifier) when is_binary(issue_id) do
    %{
      issue_id: issue_id,
      issue_identifier: issue_identifier,
      run_id: nil,
      status: "unknown",
      version: 0,
      session_count: 0,
      turn_count: 0,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      consecutive_failures: 0,
      first_started_at: nil,
      last_started_at: nil,
      last_updated_at: nil,
      worker_host: nil,
      workspace_path: nil,
      thread_id: nil,
      session_id: nil,
      prompt_hash: nil,
      prompt_bytes: nil,
      budget: nil,
      retry_attempt: 0,
      retry_due_at: nil,
      terminal_reason: nil,
      last_error: nil,
      usage_reconciliation: nil,
      event_count: 0,
      last_event_id: nil,
      recent_event_ids: []
    }
  end

  @doc false
  @spec apply_event(issue_snapshot(), map(), pos_integer()) :: {:ok, issue_snapshot()} | {:error, term()}
  def apply_event(issue, event, retention)
      when is_map(issue) and is_map(event) and is_integer(retention) and retention > 0 do
    type = event["type"]
    data = event["data"]
    run_id = Map.get(data, "run_id")

    with :ok <- validate_transition(issue, type, run_id, data) do
      updated =
        issue
        |> apply_common_data(data)
        |> apply_type(type, data, event["recorded_at"])
        |> Map.put(:issue_identifier, event["issue_identifier"] || issue.issue_identifier)
        |> Map.put(:version, issue.version + 1)
        |> Map.put(:last_updated_at, event["recorded_at"])
        |> Map.put(:last_event_id, event["event_id"])
        |> retain_event(event["event_id"], retention)

      {:ok, updated}
    end
  end

  defp normalize_options(opts) do
    with :ok <- validate_option_keys(opts) do
      normalize_option_values(opts)
    end
  end

  defp validate_option_keys(opts) do
    supported = [:max_event_bytes, :max_events_per_issue, :fault_injector]

    cond do
      not Keyword.keyword?(opts) -> {:error, :invalid_ledger_options}
      duplicate_option_keys?(opts) -> {:error, :invalid_ledger_options}
      Enum.any?(Keyword.keys(opts), &(&1 not in supported)) -> {:error, :invalid_ledger_options}
      true -> :ok
    end
  end

  defp duplicate_option_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp normalize_option_values(opts) do
    normalized_options = %{
      max_event_bytes: Keyword.get(opts, :max_event_bytes, @default_max_event_bytes),
      max_events_per_issue: Keyword.get(opts, :max_events_per_issue, @default_max_events_per_issue),
      fault_injector: Keyword.get(opts, :fault_injector)
    }

    if valid_option_values?(normalized_options) do
      {:ok, normalized_options}
    else
      {:error, :invalid_ledger_options}
    end
  end

  defp valid_option_values?(%{
         max_event_bytes: max_event_bytes,
         max_events_per_issue: max_events_per_issue,
         fault_injector: fault_injector
       }) do
    is_integer(max_event_bytes) and max_event_bytes > 0 and
      is_integer(max_events_per_issue) and max_events_per_issue > 0 and
      (is_nil(fault_injector) or is_function(fault_injector, 1))
  end

  @spec validate_map_keys(map(), [String.t()]) :: :ok | {:error, :invalid_ledger_event_shape}
  defp validate_map_keys(map, allowed_keys) when is_map(map) do
    normalized_keys = Enum.map(Map.keys(map), &normalize_map_key/1)

    if Enum.all?(normalized_keys, &is_binary/1) and
         length(normalized_keys) == MapSet.size(MapSet.new(normalized_keys)) and
         Enum.all?(normalized_keys, &(&1 in allowed_keys)) do
      :ok
    else
      {:error, :invalid_ledger_event_shape}
    end
  end

  defp normalize_map_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_map_key(key) when is_binary(key), do: key
  defp normalize_map_key(_key), do: nil

  defp normalize_persisted_event(event) when is_map(event) do
    with :ok <- validate_persisted_event_shape(event),
         {:ok, normalized_event, opts} <- normalize_event(Map.take(event, @public_event_keys), []),
         true <- Map.get(event, "schema_version") == @schema_version,
         true <- Map.has_key?(event, "recorded_at"),
         true <- Map.get(normalized_event, "recorded_at") == Map.get(event, "recorded_at"),
         %{} = identity <- Map.get(event, "identity"),
         identity_recorded_at <- Map.get(identity, "recorded_at"),
         true <- identity_recorded_at in [nil, normalized_event["recorded_at"]],
         expected_identity <-
           normalized_event
           |> Map.put("recorded_at", identity_recorded_at)
           |> Map.delete("schema_version")
           |> Map.delete("identity"),
         true <- expected_identity == identity do
      {:ok, Map.put(normalized_event, "identity", identity), opts}
    else
      false -> {:error, :invalid_persisted_event}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_persisted_event(_event), do: {:error, :invalid_persisted_event}

  defp validate_persisted_event_shape(event) do
    if Enum.all?(Map.keys(event), &is_binary/1) do
      case validate_map_keys(event, @persisted_event_keys) do
        :ok -> :ok
        {:error, _reason} -> {:error, :invalid_persisted_event}
      end
    else
      {:error, :invalid_persisted_event}
    end
  end

  defp validate_persisted_commit_shape(commit) do
    if Enum.all?(Map.keys(commit), &is_binary/1) and
         MapSet.equal?(MapSet.new(Map.keys(commit)), @commit_keys) do
      :ok
    else
      {:error, :invalid_commit}
    end
  end

  defp valid_base_last_event_id?(0, nil), do: true

  defp valid_base_last_event_id?(base_version, event_id) when base_version > 0,
    do: valid_projection_event_id?(event_id)

  defp valid_base_last_event_id?(_base_version, _event_id), do: false

  defp required_string(event, key) do
    case value(event, key) do
      string when is_binary(string) ->
        string = String.trim(string)

        if string != "" and byte_size(string) <= @max_string_bytes do
          {:ok, string}
        else
          {:error, {:invalid_ledger_event, key}}
        end

      _ ->
        {:error, {:invalid_ledger_event, key}}
    end
  end

  defp optional_string(event, key) do
    value(event, key)
    |> normalize_optional_string(key)
  end

  defp normalize_optional_string(nil, _key), do: {:ok, nil}

  defp normalize_optional_string(string, key) when is_binary(string) do
    string
    |> String.trim()
    |> normalize_trimmed_optional_string(key)
  end

  defp normalize_optional_string(_value, key), do: {:error, {:invalid_ledger_event, key}}

  defp normalize_trimmed_optional_string("", _key), do: {:ok, nil}

  defp normalize_trimmed_optional_string(string, _key) when byte_size(string) <= @max_string_bytes,
    do: {:ok, string}

  defp normalize_trimmed_optional_string(_string, key), do: {:error, {:invalid_ledger_event, key}}

  defp required_type(event) do
    case value(event, :type) do
      type when is_atom(type) ->
        required_type(%{"type" => Atom.to_string(type)})

      type when is_binary(type) ->
        type = String.trim(type)

        if MapSet.member?(@event_types, type) do
          {:ok, type}
        else
          {:error, {:invalid_ledger_event_type, type}}
        end

      _ ->
        {:error, {:invalid_ledger_event, :type}}
    end
  end

  defp normalize_recorded_at(nil) do
    recorded_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    {:ok, recorded_at, nil}
  end

  defp normalize_recorded_at(%DateTime{} = datetime) do
    recorded_at = datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    {:ok, recorded_at, recorded_at}
  end

  defp normalize_recorded_at(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> normalize_recorded_at(datetime)
      _ -> {:error, {:invalid_ledger_timestamp, value}}
    end
  end

  defp normalize_recorded_at(_value), do: {:error, {:invalid_ledger_timestamp, :invalid}}

  defp normalize_data(type, data) when is_map(data) do
    data
    |> stringify_keys()
    |> normalize_data_by_type(type)
  end

  defp normalize_data(_type, _data), do: {:error, {:invalid_ledger_event, :data}}

  defp normalize_data_by_type(data, "dispatch"), do: normalize_dispatch_data(data)
  defp normalize_data_by_type(data, "worker_started"), do: normalize_worker_started_data(data)
  defp normalize_data_by_type(data, "turn_reserved"), do: normalize_turn_reserved_data(data)
  defp normalize_data_by_type(data, "turn_started"), do: normalize_turn_started_data(data)
  defp normalize_data_by_type(data, "usage"), do: normalize_usage_data(data)
  defp normalize_data_by_type(data, "runtime_info"), do: normalize_runtime_info_data(data)
  defp normalize_data_by_type(data, "worker_completed"), do: normalize_worker_completed_data(data)

  defp normalize_data_by_type(data, type) when type in ["failure", "retry_scheduled", "continuation_scheduled"],
    do: normalize_retry_data(data)

  defp normalize_data_by_type(data, type) when type in ["blocked", "budget_exhausted", "terminal", "released", "abandoned"],
    do: normalize_terminal_data(data)

  defp normalize_data_by_type(data, "note"), do: normalize_note_data(data)

  defp normalize_dispatch_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         {:ok, data} <- allow_data(data, ["run_id", "worker_host", "workspace_path", "budget", "retry_attempt"]),
         {:ok, data} <- normalize_optional_data_strings(data, ["worker_host", "workspace_path"]),
         {:ok, data} <- normalize_budget_data(data) do
      normalize_optional_non_negative(data, "retry_attempt")
    end
  end

  defp normalize_worker_started_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         {:ok, data} <- allow_data(data, ["run_id", "worker_host", "workspace_path", "budget", "retry_attempt"]),
         {:ok, data} <- normalize_optional_data_strings(data, ["worker_host", "workspace_path"]),
         {:ok, data} <- normalize_budget_data(data) do
      normalize_optional_non_negative(data, "retry_attempt")
    end
  end

  defp normalize_turn_started_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         :ok <- require_data_string(data, "session_id"),
         {:ok, data} <- allow_data(data, ["run_id", "thread_id", "session_id"]) do
      normalize_optional_data_strings(data, ["thread_id"])
    end
  end

  defp normalize_turn_reserved_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         {:ok, data} <- allow_data(data, ["run_id", "thread_id", "turn_number"]),
         {:ok, data} <- normalize_optional_data_strings(data, ["thread_id"]) do
      normalize_required_positive(data, "turn_number")
    end
  end

  defp normalize_usage_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         {:ok, data} <- allow_data(data, ["run_id", "input_tokens", "output_tokens", "total_tokens"]),
         {:ok, data} <- normalize_required_non_negative(data, "input_tokens"),
         {:ok, data} <- normalize_required_non_negative(data, "output_tokens") do
      normalize_required_non_negative(data, "total_tokens")
    end
  end

  defp normalize_runtime_info_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         {:ok, data} <- allow_data(data, ["run_id", "worker_host", "workspace_path", "session_id", "thread_id"]) do
      normalize_optional_data_strings(data, ["worker_host", "workspace_path", "session_id", "thread_id"])
    end
  end

  defp normalize_worker_completed_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         {:ok, data} <-
           allow_data(data, [
             "run_id",
             "worker_host",
             "workspace_path",
             "session_id",
             "thread_id",
             "retry_attempt",
             "retry_due_at",
             "error",
             "usage_reconciliation"
           ]),
         {:ok, data} <- normalize_optional_data_strings(data, ["worker_host", "workspace_path", "session_id", "thread_id"]),
         {:ok, data} <- normalize_optional_non_negative(data, "retry_attempt"),
         {:ok, data} <- normalize_optional_timestamp(data, "retry_due_at"),
         {:ok, data} <- normalize_optional_error(data) do
      normalize_optional_usage_reconciliation(data)
    end
  end

  defp normalize_retry_data(data) do
    with :ok <- require_data_string(data, "run_id"),
         {:ok, data} <-
           allow_data(data, [
             "run_id",
             "worker_host",
             "workspace_path",
             "session_id",
             "thread_id",
             "retry_attempt",
             "retry_due_at",
             "error",
             "usage_reconciliation",
             "restart_recovery"
           ]),
         {:ok, data} <- normalize_optional_data_strings(data, ["worker_host", "workspace_path", "session_id", "thread_id"]),
         {:ok, data} <- normalize_optional_non_negative(data, "retry_attempt"),
         {:ok, data} <- normalize_optional_timestamp(data, "retry_due_at"),
         {:ok, data} <- normalize_optional_error(data),
         {:ok, data} <- normalize_optional_usage_reconciliation(data) do
      normalize_optional_restart_recovery(data)
    end
  end

  defp normalize_terminal_data(data) do
    with {:ok, data} <-
           allow_data(data, [
             "run_id",
             "worker_host",
             "workspace_path",
             "session_id",
             "thread_id",
             "error",
             "reason",
             "terminal_reason",
             "usage_reconciliation"
           ]),
         {:ok, data} <- normalize_optional_data_strings(data, ["run_id", "worker_host", "workspace_path", "session_id", "thread_id"]),
         {:ok, data} <- normalize_optional_error(data),
         {:ok, data} <- normalize_optional_reason(data) do
      normalize_optional_usage_reconciliation(data)
    end
  end

  defp normalize_note_data(data) do
    case allow_data(data, ["detail"]) do
      {:ok, data} -> normalize_optional_detail(data)
      {:error, _reason} = error -> error
    end
  end

  defp allow_data(data, allowed_keys) do
    if Enum.all?(Map.keys(data), &(&1 in allowed_keys)) do
      {:ok, Map.new(data, fn {key, value} -> {key, normalize_allowed_value(key, value)} end)}
    else
      {:error, {:invalid_ledger_event_data, :unsupported_key}}
    end
  end

  defp normalize_allowed_value(_key, value), do: value

  defp normalize_optional_data_strings(data, keys) when is_map(data) and is_list(keys) do
    Enum.reduce_while(keys, {:ok, data}, &normalize_optional_data_string/2)
  end

  defp normalize_optional_data_string(key, {:ok, data}) do
    case Map.fetch(data, key) do
      :error -> {:cont, {:ok, data}}
      {:ok, nil} -> {:cont, {:ok, Map.delete(data, key)}}
      {:ok, value} when is_binary(value) -> normalize_present_optional_data_string(data, key, value)
      {:ok, _value} -> {:halt, {:error, {:invalid_ledger_event_data, key}}}
    end
  end

  defp normalize_present_optional_data_string(data, key, value) do
    normalized_value = String.trim(value)

    if valid_optional_data_string?(normalized_value) do
      {:cont, {:ok, Map.put(data, key, normalized_value)}}
    else
      {:halt, {:error, {:invalid_ledger_event_data, key}}}
    end
  end

  defp valid_optional_data_string?(value) do
    value != "" and byte_size(value) <= @max_string_bytes
  end

  defp normalize_budget_data(data) do
    case Map.fetch(data, "budget") do
      :error -> {:ok, data}
      {:ok, budget} when is_map(budget) -> normalize_budget_map(data, budget)
      {:ok, _other} -> {:error, {:invalid_ledger_event_data, :budget}}
    end
  end

  defp normalize_budget_map(data, budget) do
    normalized_budget = stringify_keys(budget)

    if valid_budget_data?(normalized_budget) do
      {:ok, Map.put(data, "budget", normalized_budget)}
    else
      {:error, {:invalid_ledger_event_data, :budget}}
    end
  end

  defp valid_budget_data?(budget), do: Enum.all?(budget, &valid_budget_entry?/1)

  defp valid_budget_entry?({key, value}) do
    MapSet.member?(@budget_keys, key) and (is_nil(value) or (is_integer(value) and value > 0))
  end

  defp normalize_required_non_negative(data, key) do
    case Map.get(data, key) do
      value when is_integer(value) and value >= 0 -> {:ok, data}
      _ -> {:error, {:invalid_ledger_event_data, key}}
    end
  end

  defp normalize_required_positive(data, key) do
    case Map.get(data, key) do
      value when is_integer(value) and value > 0 -> {:ok, data}
      _ -> {:error, {:invalid_ledger_event_data, key}}
    end
  end

  defp normalize_optional_non_negative(data, key) do
    case Map.fetch(data, key) do
      :error -> {:ok, data}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, data}
      {:ok, _value} -> {:error, {:invalid_ledger_event_data, key}}
    end
  end

  defp normalize_optional_timestamp(data, key) do
    case Map.fetch(data, key) do
      :error ->
        {:ok, data}

      {:ok, value} ->
        case normalize_recorded_at(value) do
          {:ok, normalized, _identity} -> {:ok, Map.put(data, key, normalized)}
          {:error, _reason} -> {:error, {:invalid_ledger_event_data, key}}
        end
    end
  end

  defp normalize_optional_error(data) do
    case Map.fetch(data, "error") do
      :error -> {:ok, data}
      {:ok, nil} -> {:ok, Map.delete(data, "error")}
      {:ok, value} when is_binary(value) -> {:ok, Map.put(data, "error", sanitize_message(value))}
      {:ok, _value} -> {:error, {:invalid_ledger_event_data, :error}}
    end
  end

  defp normalize_optional_usage_reconciliation(data) do
    case Map.fetch(data, "usage_reconciliation") do
      :error ->
        {:ok, data}

      {:ok, value} when is_binary(value) ->
        if MapSet.member?(@usage_reconciliations, value) do
          {:ok, data}
        else
          {:error, {:invalid_ledger_event_data, :usage_reconciliation}}
        end

      {:ok, _value} ->
        {:error, {:invalid_ledger_event_data, :usage_reconciliation}}
    end
  end

  defp normalize_optional_restart_recovery(data) do
    case Map.fetch(data, "restart_recovery") do
      :error ->
        {:ok, data}

      {:ok, true} ->
        {:ok, data}

      {:ok, _value} ->
        {:error, {:invalid_ledger_event_data, :restart_recovery}}
    end
  end

  defp normalize_optional_reason(data) do
    Enum.reduce_while(data, {:ok, data}, &normalize_reason_entry/2)
  end

  defp normalize_reason_entry({key, value}, {:ok, data}) when key in ["reason", "terminal_reason"] do
    case normalize_reason_value(value, key) do
      {:ok, normalized_value} -> {:cont, {:ok, Map.put(data, key, normalized_value)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp normalize_reason_entry(_entry, {:ok, data}), do: {:cont, {:ok, data}}

  defp normalize_reason_value(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_ledger_event_data, key}}
      normalized_value -> {:ok, normalized_value |> sanitize_message() |> truncate_string()}
    end
  end

  defp normalize_reason_value(_value, key), do: {:error, {:invalid_ledger_event_data, key}}

  defp normalize_optional_detail(data) do
    case Map.fetch(data, "detail") do
      :error -> {:ok, data}
      {:ok, value} when is_binary(value) -> {:ok, Map.put(data, "detail", sanitize_message(value))}
      {:ok, _value} -> {:error, {:invalid_ledger_event_data, :detail}}
    end
  end

  defp require_data_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and byte_size(value) <= @max_string_bytes ->
        if String.trim(value) == "", do: {:error, {:invalid_ledger_event_data, key}}, else: :ok

      _ ->
        {:error, {:invalid_ledger_event_data, key}}
    end
  end

  defp validate_transition(issue, "dispatch", run_id, _data) do
    if is_binary(run_id) and run_id != "" and issue.status not in ["dispatching", "running"] do
      :ok
    else
      {:error, {:invalid_ledger_transition, issue.status, "dispatch"}}
    end
  end

  defp validate_transition(issue, "worker_started", run_id, _data) do
    if same_current_run?(issue, run_id) and issue.status == "dispatching" do
      :ok
    else
      {:error, {:stale_or_invalid_run, run_id}}
    end
  end

  defp validate_transition(issue, type, run_id, _data)
       when type in ["turn_reserved", "turn_started", "usage", "runtime_info", "worker_completed"] do
    validate_current_run_status(issue, run_id, type, ["running"])
  end

  defp validate_transition(issue, "failure", run_id, _data) do
    validate_current_run_status(issue, run_id, "failure", ["dispatching", "running"])
  end

  defp validate_transition(issue, "retry_scheduled", run_id, data) do
    cond do
      same_current_run?(issue, run_id) and issue.status == "failing" ->
        :ok

      same_current_run?(issue, run_id) and data["restart_recovery"] == true and
          issue.status in ["dispatching", "running"] ->
        :ok

      not same_current_run?(issue, run_id) ->
        {:error, {:stale_or_invalid_run, run_id}}

      true ->
        {:error, {:invalid_ledger_transition, issue.status, "retry_scheduled"}}
    end
  end

  defp validate_transition(issue, "continuation_scheduled", run_id, _data) do
    validate_current_run_status(issue, run_id, "continuation_scheduled", ["continuing"])
  end

  defp validate_transition(issue, "blocked", run_id, _data) do
    validate_current_run_status(issue, run_id, "blocked", ["dispatching", "running", "continuing", "failing", "retrying"])
  end

  defp validate_transition(issue, "budget_exhausted", run_id, _data) do
    validate_matching_or_absent_run_status(
      issue,
      run_id,
      "budget_exhausted",
      ["dispatching", "running", "continuing", "failing", "retrying"]
    )
  end

  defp validate_transition(issue, type, run_id, _data) when type in ["terminal", "released", "abandoned"] do
    validate_matching_or_absent_run_status(
      issue,
      run_id,
      type,
      ["dispatching", "running", "continuing", "failing", "retrying", "blocked", "budget_exhausted", "terminal", "released", "abandoned"]
    )
  end

  defp validate_transition(_issue, "note", _run_id, _data), do: :ok

  defp validate_current_run_status(issue, run_id, type, statuses) do
    cond do
      not same_current_run?(issue, run_id) -> {:error, {:stale_or_invalid_run, run_id}}
      issue.status in statuses -> :ok
      true -> {:error, {:invalid_ledger_transition, issue.status, type}}
    end
  end

  defp validate_matching_or_absent_run_status(issue, run_id, type, statuses) do
    cond do
      not (is_nil(run_id) or same_current_run?(issue, run_id)) ->
        {:error, {:stale_or_invalid_run, run_id}}

      issue.status in statuses ->
        :ok

      true ->
        {:error, {:invalid_ledger_transition, issue.status, type}}
    end
  end

  defp same_current_run?(issue, run_id), do: is_binary(run_id) and issue.run_id == run_id

  defp apply_common_data(issue, data) do
    %{
      issue
      | issue_identifier: Map.get(data, "issue_identifier", issue.issue_identifier),
        worker_host: Map.get(data, "worker_host", issue.worker_host),
        workspace_path: Map.get(data, "workspace_path", issue.workspace_path),
        thread_id: Map.get(data, "thread_id", issue.thread_id),
        session_id: Map.get(data, "session_id", issue.session_id),
        budget: Map.get(data, "budget", issue.budget),
        retry_attempt: Map.get(data, "retry_attempt", issue.retry_attempt),
        retry_due_at: Map.get(data, "retry_due_at", issue.retry_due_at),
        terminal_reason: Map.get(data, "terminal_reason") || Map.get(data, "reason") || issue.terminal_reason,
        last_error: Map.get(data, "error", issue.last_error),
        usage_reconciliation: Map.get(data, "usage_reconciliation", issue.usage_reconciliation)
    }
  end

  defp apply_type(issue, "dispatch", data, recorded_at) do
    %{
      issue
      | run_id: data["run_id"],
        status: "dispatching",
        first_started_at: issue.first_started_at || recorded_at,
        last_started_at: recorded_at,
        worker_host: Map.get(data, "worker_host"),
        workspace_path: Map.get(data, "workspace_path"),
        thread_id: nil,
        session_id: nil,
        retry_attempt: Map.get(data, "retry_attempt", 0),
        retry_due_at: nil,
        terminal_reason: nil,
        last_error: nil,
        usage_reconciliation: nil,
        prompt_hash: nil,
        prompt_bytes: nil
    }
  end

  defp apply_type(issue, "worker_started", _data, _recorded_at) do
    %{issue | status: "running", session_count: issue.session_count + 1}
  end

  defp apply_type(issue, "turn_started", _data, _recorded_at) do
    %{issue | status: "running", turn_count: issue.turn_count + 1}
  end

  defp apply_type(issue, "turn_reserved", _data, _recorded_at) do
    %{issue | status: "running", turn_count: issue.turn_count + 1}
  end

  defp apply_type(issue, "usage", data, _recorded_at) do
    %{
      issue
      | input_tokens: issue.input_tokens + data["input_tokens"],
        output_tokens: issue.output_tokens + data["output_tokens"],
        total_tokens: issue.total_tokens + data["total_tokens"]
    }
  end

  defp apply_type(issue, "runtime_info", _data, _recorded_at), do: issue
  defp apply_type(issue, "worker_completed", _data, _recorded_at), do: %{issue | status: "continuing", consecutive_failures: 0}
  defp apply_type(issue, "failure", _data, _recorded_at), do: %{issue | status: "failing", consecutive_failures: issue.consecutive_failures + 1}
  defp apply_type(issue, type, _data, _recorded_at) when type in ["retry_scheduled", "continuation_scheduled"], do: %{issue | status: "retrying"}
  defp apply_type(issue, "blocked", _data, _recorded_at), do: %{issue | status: "blocked"}
  defp apply_type(issue, "budget_exhausted", _data, _recorded_at), do: %{issue | status: "budget_exhausted"}
  defp apply_type(issue, "terminal", _data, _recorded_at), do: %{issue | status: "terminal"}
  defp apply_type(issue, "released", _data, _recorded_at), do: %{issue | status: "released"}
  defp apply_type(issue, "abandoned", _data, _recorded_at), do: %{issue | status: "abandoned"}
  defp apply_type(issue, "note", _data, _recorded_at), do: issue

  defp retain_event(issue, event_id, retention) do
    recent_event_ids = [event_id | issue.recent_event_ids] |> Enum.take(retention)
    %{issue | recent_event_ids: recent_event_ids, event_count: length(recent_event_ids)}
  end

  defp validate_projection(projection, retention)
       when is_map(projection) and is_integer(retention) and retention > 0 do
    with :ok <- validate_projection_shape(projection),
         {:ok, normalized_projection} <- validate_projection(projection),
         true <- normalized_projection.event_count <= retention,
         true <- Enum.all?(normalized_projection.recent_event_ids, &valid_projection_event_id?/1),
         true <- length(Enum.uniq(normalized_projection.recent_event_ids)) == normalized_projection.event_count do
      {:ok, normalized_projection}
    else
      false -> {:error, :invalid_projection}
      {:error, _reason} = error -> error
    end
  end

  defp validate_projection(_projection, _retention), do: {:error, :invalid_projection}

  defp validate_projection(projection) when is_map(projection) do
    required_non_negative = [
      :version,
      :session_count,
      :turn_count,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :consecutive_failures,
      :retry_attempt,
      :event_count
    ]

    with issue_id when is_binary(issue_id) and issue_id != "" and byte_size(issue_id) <= @max_string_bytes <- Map.get(projection, :issue_id),
         status when is_binary(status) <- Map.get(projection, :status),
         true <- MapSet.member?(@issue_statuses, status),
         true <- Enum.all?(required_non_negative, &(is_integer(Map.get(projection, &1)) and Map.get(projection, &1) >= 0)),
         true <- Map.get(projection, :version) >= Map.get(projection, :event_count),
         true <- valid_timestamp_or_nil?(Map.get(projection, :first_started_at)),
         true <- valid_timestamp_or_nil?(Map.get(projection, :last_started_at)),
         true <- valid_timestamp_or_nil?(Map.get(projection, :last_updated_at)),
         true <- valid_timestamp_or_nil?(Map.get(projection, :retry_due_at)),
         true <- valid_budget_or_nil?(Map.get(projection, :budget)),
         true <- valid_projection_strings?(projection),
         true <- valid_prompt_metadata?(projection),
         true <- valid_usage_reconciliation?(Map.get(projection, :usage_reconciliation)),
         true <- is_list(Map.get(projection, :recent_event_ids)) and Map.get(projection, :event_count) == length(Map.get(projection, :recent_event_ids)) do
      {:ok, projection}
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp validate_projection_shape(projection) do
    if Enum.all?(Map.keys(projection), &is_atom/1) and
         MapSet.equal?(MapSet.new(Map.keys(projection)), @projection_keys) do
      :ok
    else
      {:error, :invalid_projection}
    end
  end

  defp valid_projection_event_id?(value) when is_binary(value), do: String.trim(value) != "" and byte_size(value) <= @max_string_bytes
  defp valid_projection_event_id?(_value), do: false

  defp valid_projection_strings?(projection) do
    Enum.all?(
      [
        :issue_identifier,
        :run_id,
        :worker_host,
        :workspace_path,
        :thread_id,
        :session_id,
        :terminal_reason,
        :last_error
      ],
      fn key -> valid_optional_projection_string?(Map.get(projection, key)) end
    ) and valid_projection_event_id?(Map.get(projection, :last_event_id))
  end

  defp valid_optional_projection_string?(nil), do: true

  defp valid_optional_projection_string?(value) when is_binary(value),
    do: byte_size(value) <= @max_string_bytes

  defp valid_optional_projection_string?(_value), do: false

  defp valid_prompt_metadata?(projection) do
    valid_optional_projection_string?(Map.get(projection, :prompt_hash)) and
      case Map.get(projection, :prompt_bytes) do
        nil -> true
        bytes when is_integer(bytes) and bytes >= 0 -> true
        _ -> false
      end
  end

  defp valid_usage_reconciliation?(nil), do: true
  defp valid_usage_reconciliation?(value) when is_binary(value), do: MapSet.member?(@usage_reconciliations, value)
  defp valid_usage_reconciliation?(_value), do: false

  defp valid_timestamp_or_nil?(nil), do: true

  defp valid_timestamp_or_nil?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp_or_nil?(_value), do: false

  defp valid_budget_or_nil?(nil), do: true

  defp valid_budget_or_nil?(budget) when is_map(budget) do
    Enum.all?(budget, fn {key, value} ->
      is_binary(key) and MapSet.member?(@budget_keys, key) and
        (is_nil(value) or (is_integer(value) and value > 0))
    end)
  end

  defp valid_budget_or_nil?(_budget), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp sanitize_message(value) when is_binary(value) do
    value
    |> SensitiveData.redact_string()
    |> String.replace(~r/(?i)(authorization|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie)\s*[:=]\s*[^\s,;]+/, "\\1=[REDACTED]")
    |> String.replace(~r/(?i)bearer\s+[^\s,;]+/, "Bearer [REDACTED]")
    |> String.replace(~r/\bsk-[A-Za-z0-9_-]+\b/, "[REDACTED]")
    |> truncate_to(@max_error_bytes)
  end

  defp truncate_string(value) when is_binary(value), do: truncate_to(value, @max_string_bytes)

  defp truncate_to(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes do
    String.slice(value, 0, max_bytes) <> "…[truncated]"
  end

  defp truncate_to(value, _max_bytes), do: value

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
