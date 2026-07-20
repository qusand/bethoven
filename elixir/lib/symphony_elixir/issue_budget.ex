defmodule SymphonyElixir.IssueBudget do
  @moduledoc false

  @budget_keys [
    :max_sessions,
    :max_turns,
    :max_tokens,
    :max_wall_time_ms,
    :max_consecutive_failures
  ]

  @type limit :: pos_integer() | nil
  @type policy :: %{optional(atom()) => limit()}

  @spec exhaustion_reason(map(), policy(), DateTime.t()) :: atom() | nil
  def exhaustion_reason(issue_run, budget, %DateTime{} = now)
      when is_map(issue_run) and is_map(budget) do
    cond do
      reached?(value(issue_run, :session_count), limit(budget, :max_sessions)) ->
        :max_sessions

      reached?(value(issue_run, :turn_count), limit(budget, :max_turns)) ->
        :max_turns

      reached?(value(issue_run, :total_tokens), limit(budget, :max_tokens)) ->
        :max_tokens

      wall_time_reached?(value(issue_run, :first_started_at), limit(budget, :max_wall_time_ms), now) ->
        :max_wall_time_ms

      reached?(value(issue_run, :consecutive_failures), limit(budget, :max_consecutive_failures)) ->
        :max_consecutive_failures

      true ->
        nil
    end
  end

  @spec reached?(term(), term()) :: boolean()
  def reached?(_value, nil), do: false

  def reached?(value, limit) when is_integer(limit) and limit > 0 do
    (integer_like(value) || 0) >= limit
  end

  def reached?(_value, _limit), do: false

  @spec normalize(term()) :: policy()
  def normalize(budget) when is_map(budget) do
    Map.new(@budget_keys, fn key -> {key, limit(budget, key)} end)
  end

  def normalize(_budget), do: %{}

  @spec merge_stricter(policy(), policy()) :: policy()
  def merge_stricter(persisted_budget, configured_budget)
      when is_map(persisted_budget) and is_map(configured_budget) do
    Map.new(@budget_keys, fn key ->
      {key, stricter_limit(Map.get(persisted_budget, key), Map.get(configured_budget, key))}
    end)
  end

  def merge_stricter(_persisted_budget, configured_budget) when is_map(configured_budget) do
    merge_stricter(%{}, configured_budget)
  end

  def merge_stricter(persisted_budget, _configured_budget) when is_map(persisted_budget) do
    merge_stricter(persisted_budget, %{})
  end

  def merge_stricter(_persisted_budget, _configured_budget), do: merge_stricter(%{}, %{})

  defp wall_time_reached?(_started_at, nil, _now), do: false

  defp wall_time_reached?(started_at, limit, %DateTime{} = now)
       when is_integer(limit) and limit > 0 do
    case datetime_or_nil(started_at) do
      %DateTime{} = started -> DateTime.diff(now, started, :millisecond) >= limit
      nil -> false
    end
  end

  defp datetime_or_nil(%DateTime{} = datetime), do: datetime

  defp datetime_or_nil(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime_or_nil(_value), do: nil

  defp limit(budget, key) do
    budget
    |> value(key)
    |> integer_like()
  end

  defp value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp stricter_limit(nil, nil), do: nil
  defp stricter_limit(nil, configured), do: configured
  defp stricter_limit(persisted, nil), do: persisted
  defp stricter_limit(persisted, configured), do: min(persisted, configured)

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _remainder} when number >= 0 -> number
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
