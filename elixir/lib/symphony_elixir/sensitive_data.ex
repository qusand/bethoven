defmodule SymphonyElixir.SensitiveData do
  @moduledoc false

  @redacted "[REDACTED]"
  @truncated "[TRUNCATED]"
  @max_depth 8
  @max_collection_size 100
  @max_string_length 4_096
  @sensitive_key_names [
    "apikey",
    "xapikey",
    "accesstoken",
    "refreshtoken",
    "authorization",
    "password",
    "secret",
    "credential",
    "credentials",
    "token"
  ]
  @sensitive_key_suffixes [
    "apikey",
    "accesstoken",
    "refreshtoken",
    "authorization",
    "password",
    "secret",
    "credential",
    "credentials"
  ]

  @credential_assignment ~r/(?ix)
    \b(api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|x[_-]?api[_-]?key|password|secret|credentials?|token)\b
    \s*(?:=>|:|=)\s*
    (?:(?:bearer|basic)\s+[^,\s}\]]+|"[^"]*"|'[^']*'|[^,\s}\]]+)
  /
  @bearer_credential ~r/(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+\/-]+=*/

  @spec redact(term()) :: term()
  def redact(value), do: redact(value, 0)

  defp redact(_value, depth) when depth > @max_depth, do: @truncated

  defp redact(value, _depth) when is_binary(value), do: redact_string(value)

  defp redact(%{__struct__: module} = value, depth) when is_atom(module) do
    case verified_struct_module(value, module) do
      {:ok, ^module} -> redact_verified_struct(value, module, depth)
      :error -> redact_map(value, depth)
    end
  end

  defp redact(value, depth) when is_map(value), do: redact_map(value, depth)

  defp redact(value, depth) when is_list(value), do: redact_list(value, depth, 0, [])

  defp redact(value, depth) when is_tuple(value) do
    redact_tuple(value, depth, 0, min(tuple_size(value), @max_collection_size), [])
  end

  defp redact(value, _depth), do: value

  @spec redact_string(String.t()) :: String.t()
  def redact_string(value) when is_binary(value) do
    value
    |> bounded_string()
    |> then(&Regex.replace(@credential_assignment, &1, "\\1=#{@redacted}"))
    |> then(&Regex.replace(@bearer_credential, &1, "Bearer #{@redacted}"))
  end

  @spec safe_inspect(term()) :: String.t()
  def safe_inspect(value), do: inspect(redact(value), limit: 100, printable_limit: 4_096)

  defp redact_map(value, depth) do
    value
    |> :maps.iterator()
    |> take_map_entries(@max_collection_size, [])
    |> Map.new(&redact_map_entry(&1, depth))
  end

  defp take_map_entries(_iterator, 0, acc), do: Enum.reverse(acc)

  defp take_map_entries(iterator, remaining, acc) do
    case :maps.next(iterator) do
      {key, value, next} -> take_map_entries(next, remaining - 1, [{key, value} | acc])
      :none -> Enum.reverse(acc)
    end
  end

  defp redact_verified_struct(value, module, depth) do
    value
    |> Map.delete(:__struct__)
    |> Map.new(&redact_struct_entry(&1, depth))
    |> Map.put(:__struct__, module)
  end

  defp redact_struct_entry({key, nested_value}, depth) do
    if sensitive_key?(key) do
      {key, @redacted}
    else
      {key, redact(nested_value, depth + 1)}
    end
  end

  defp redact_map_entry({key, nested_value}, depth) do
    safe_key = if key == :__struct__, do: "__struct__", else: redact_map_key(key)

    if sensitive_key?(key) do
      {safe_key, @redacted}
    else
      {safe_key, redact(nested_value, depth + 1)}
    end
  end

  defp redact_map_key(key) when is_binary(key), do: bounded_key(key)

  defp redact_map_key(key) when is_atom(key) do
    string_key = Atom.to_string(key)
    safe_key = redact_string(string_key)
    if safe_key == string_key, do: key, else: safe_key
  end

  defp redact_map_key(key) when is_number(key), do: key
  defp redact_map_key(_key), do: @truncated

  defp bounded_key(key) when byte_size(key) > @max_string_length, do: @truncated
  defp bounded_key(key), do: redact_string(key)

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()

  defp sensitive_key?(key) when is_binary(key) and byte_size(key) > @max_string_length, do: true
  defp sensitive_key?(key) when is_binary(key), do: sensitive_binary_key?(key)

  defp sensitive_key?(_key), do: false

  defp sensitive_binary_key?(key) do
    if String.valid?(key) do
      normalized_key_sensitive?(key)
    else
      true
    end
  end

  defp normalized_key_sensitive?(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    normalized in @sensitive_key_names or sensitive_suffix?(normalized) or sensitive_token?(normalized)
  end

  defp verified_struct_module(value, module) do
    with true <- function_exported?(module, :__struct__, 0),
         %{} = template <- module.__struct__(),
         true <- map_size(value) == map_size(template),
         true <- Enum.all?(Map.keys(template), &Map.has_key?(value, &1)) do
      {:ok, module}
    else
      _reason -> :error
    end
  rescue
    _reason -> :error
  catch
    _kind, _reason -> :error
  end

  defp bounded_string(value) when byte_size(value) <= @max_string_length do
    if String.valid?(value), do: value, else: @truncated
  end

  defp bounded_string(value) do
    prefix = binary_part(value, 0, @max_string_length)
    if String.valid?(prefix), do: prefix, else: @truncated
  end

  defp redact_list(_tail, _depth, @max_collection_size, acc), do: Enum.reverse(acc)
  defp redact_list([], _depth, _count, acc), do: Enum.reverse(acc)

  defp redact_list([head | tail], depth, count, acc) do
    redact_list(tail, depth, count + 1, [redact(head, depth + 1) | acc])
  end

  defp redact_list(improper_tail, depth, _count, acc) do
    Enum.reverse([redact(improper_tail, depth + 1) | acc])
  end

  defp redact_tuple(_value, _depth, limit, limit, acc) do
    acc |> Enum.reverse() |> List.to_tuple()
  end

  defp redact_tuple(value, depth, index, limit, acc) do
    redact_tuple(value, depth, index + 1, limit, [redact(elem(value, index), depth + 1) | acc])
  end

  defp sensitive_suffix?(normalized) do
    Enum.any?(@sensitive_key_suffixes, &String.ends_with?(normalized, &1))
  end

  defp sensitive_token?(normalized) do
    String.ends_with?(normalized, "token") and not String.ends_with?(normalized, "usage")
  end
end
