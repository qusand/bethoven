defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @max_symlink_hops 40

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments, 0) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  @doc false
  @spec canonical_local_path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonical_local_path(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    case ensure_no_symlink_segments(expanded_path, allow_system_aliases: true) do
      :ok -> canonicalize(expanded_path)
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec ensure_no_symlink_segments(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_no_symlink_segments(path, opts \\ []) when is_binary(path) and is_list(opts) do
    path
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, &inspect_path_segment(&1, &2, opts))
    |> normalize_segment_result()
  end

  defp inspect_path_segment(segment, {:ok, prefix}, opts) do
    candidate = if prefix == "", do: segment, else: Path.join(prefix, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} -> symlink_segment_result(candidate, opts)
      {:ok, _stat} -> {:cont, {:ok, candidate}}
      {:error, :enoent} -> {:halt, {:ok, candidate}}
      {:error, reason} -> {:halt, {:error, {candidate, reason}}}
    end
  end

  defp symlink_segment_result(candidate, opts) do
    if Keyword.get(opts, :allow_system_aliases, false) and trusted_system_alias?(candidate) do
      {:cont, {:ok, candidate}}
    else
      {:halt, {:error, {:symlink_not_allowed, candidate}}}
    end
  end

  defp normalize_segment_result({:ok, _prefix}), do: :ok
  defp normalize_segment_result({:error, reason}), do: {:error, reason}

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(_root, _resolved_segments, _segments, hops) when hops > @max_symlink_hops,
    do: {:error, :too_many_symlink_hops}

  defp resolve_segments(root, resolved_segments, [], _hops), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest], hops) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
          resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
          {target_root, target_segments} = split_absolute_path(resolved_target)
          resolve_segments(target_root, [], target_segments ++ rest, hops + 1)
        end

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, hops)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end

  # macOS exposes both `/tmp` and `/var` as root-owned aliases into `/private`.
  # They are operating-system aliases rather than caller-controlled redirects;
  # descendants remain subject to the no-link rule.
  defp trusted_system_alias?(path), do: path in ["/tmp", "/var"]
end
