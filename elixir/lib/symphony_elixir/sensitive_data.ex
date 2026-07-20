defmodule SymphonyElixir.SensitiveData do
  @moduledoc false

  @redacted "[REDACTED]"
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
  def redact(value) when is_binary(value), do: redact_string(value)

  def redact(%DateTime{} = value), do: value
  def redact(%Date{} = value), do: value
  def redact(%Time{} = value), do: value
  def redact(%NaiveDateTime{} = value), do: value

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact(nested_value)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value), do: value

  @spec redact_string(String.t()) :: String.t()
  def redact_string(value) when is_binary(value) do
    value
    |> then(&Regex.replace(@credential_assignment, &1, "\\1=#{@redacted}"))
    |> then(&Regex.replace(@bearer_credential, &1, "Bearer #{@redacted}"))
  end

  @spec safe_inspect(term()) :: String.t()
  def safe_inspect(value), do: inspect(redact(value), limit: 100, printable_limit: 4_096)

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()

  defp sensitive_key?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

    normalized in @sensitive_key_names or sensitive_suffix?(normalized) or sensitive_token?(normalized)
  end

  defp sensitive_key?(_key), do: false

  defp sensitive_suffix?(normalized) do
    Enum.any?(@sensitive_key_suffixes, &String.ends_with?(normalized, &1))
  end

  defp sensitive_token?(normalized) do
    String.ends_with?(normalized, "token") and not String.ends_with?(normalized, "usage")
  end
end
