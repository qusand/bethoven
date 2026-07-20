defmodule SymphonyElixir.RunLedger.Storage do
  @moduledoc false

  import Bitwise

  alias SymphonyElixir.PathSafety

  @private_directory_mode 0o700
  @private_file_mode 0o600

  @type binding :: %{
          required(:path) => Path.t(),
          required(:root) => Path.t(),
          required(:root_identity) => {non_neg_integer(), non_neg_integer(), non_neg_integer()},
          optional(:leaf_identity) => {non_neg_integer(), non_neg_integer(), non_neg_integer()}
        }

  @spec prepare(Path.t()) :: {:ok, binding()} | {:error, term()}
  def prepare(path) when is_binary(path) do
    with {:ok, canonical_path} <- PathSafety.canonical_local_path(path),
         :ok <- ensure_directory_tree(Path.dirname(canonical_path)),
         :ok <- ensure_private_root(Path.dirname(canonical_path), repair: true),
         :ok <- ensure_ledger_file(canonical_path, allow_absent: true, repair: true),
         {:ok, root_identity} <- directory_identity(Path.dirname(canonical_path)) do
      {:ok,
       %{
         path: canonical_path,
         root: Path.dirname(canonical_path),
         root_identity: root_identity
       }}
    end
  end

  @spec finalize(binding()) :: :ok | {:error, term()}
  def finalize(%{path: path} = binding) do
    with :ok <- validate_root_identity(binding),
         :ok <- ensure_ledger_file(path, allow_absent: false, repair: true) do
      validate(binding)
    end
  end

  @doc false
  @spec sync_directory(Path.t()) :: :ok | {:error, term()}
  def sync_directory(path) when is_binary(path) do
    case :file.open(String.to_charlist(path), [:read, :directory, :raw]) do
      {:ok, device} -> sync_and_close_directory(device, path)
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  def sync_directory(path), do: {:error, {path, :invalid_directory}}

  @doc false
  @spec bind_ledger_leaf(binding()) :: {:ok, binding()} | {:error, term()}
  def bind_ledger_leaf(%{path: path} = binding) do
    with :ok <- validate(binding),
         {:ok, leaf_identity} <- regular_file_identity(path) do
      {:ok, Map.put(binding, :leaf_identity, leaf_identity)}
    end
  end

  def bind_ledger_leaf(_binding), do: {:error, :invalid_storage_binding}

  @spec validate(binding()) :: :ok | {:error, term()}
  def validate(%{path: path, root: root} = binding) do
    with :ok <- validate_root_identity(binding),
         :ok <- PathSafety.ensure_no_symlink_segments(path, allow_system_aliases: true),
         :ok <- ensure_existing_directory_chain(root),
         :ok <- ensure_private_root(root, repair: false),
         :ok <- ensure_ledger_file(path, allow_absent: false, repair: false) do
      validate_leaf_identity(binding)
    end
  end

  def validate(_binding), do: {:error, :invalid_storage_binding}

  defp validate_root_identity(%{root: root, root_identity: expected_identity}) do
    case directory_identity(root) do
      {:ok, ^expected_identity} -> :ok
      {:ok, _other_identity} -> {:error, {:storage_identity_changed, root}}
      {:error, _reason} -> {:error, {:storage_identity_changed, root}}
    end
  end

  defp validate_leaf_identity(%{path: path, leaf_identity: expected_identity}) do
    case regular_file_identity(path) do
      {:ok, ^expected_identity} -> :ok
      {:ok, _other_identity} -> {:error, {:ledger_file_identity_changed, path}}
      {:error, _reason} -> {:error, {:ledger_file_identity_changed, path}}
    end
  end

  defp validate_leaf_identity(_binding), do: :ok

  defp ensure_directory_tree(directory) do
    ensure_directory_chain(directory, &ensure_tree_directory/1)
  end

  defp ensure_existing_directory_chain(directory) do
    ensure_directory_chain(directory, &ensure_existing_directory/1)
  end

  defp ensure_directory_chain(directory, ensure_directory) do
    {root, segments} = split_absolute_path(directory)

    result =
      Enum.reduce_while(segments, {:ok, root}, fn segment, {:ok, parent} ->
        ensure_directory.(Path.join(parent, segment))
      end)

    directory_chain_result(result)
  end

  defp ensure_tree_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        continue_directory_chain(path, ensure_safe_ancestor(path, stat))

      {:ok, %File.Stat{type: type}} ->
        halt_directory_chain({:not_a_directory, path, type})

      {:error, :enoent} ->
        continue_directory_chain(path, create_private_directory(path))

      {:error, reason} ->
        halt_directory_chain({path, reason})
    end
  end

  defp ensure_existing_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        continue_directory_chain(path, ensure_safe_ancestor(path, stat))

      {:ok, %File.Stat{type: :symlink}} ->
        halt_directory_chain({:symlink_not_allowed, path})

      {:ok, %File.Stat{type: type}} ->
        halt_directory_chain({:not_a_directory, path, type})

      {:error, reason} ->
        halt_directory_chain({path, reason})
    end
  end

  defp continue_directory_chain(path, :ok), do: {:cont, {:ok, path}}
  defp continue_directory_chain(_path, {:error, reason}), do: halt_directory_chain(reason)
  defp halt_directory_chain(reason), do: {:halt, {:error, reason}}

  defp directory_chain_result({:ok, _directory}), do: :ok
  defp directory_chain_result({:error, reason}), do: {:error, reason}

  defp create_private_directory(path) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @private_directory_mode),
         {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path),
         :ok <- ensure_owned_by_current_user(path, stat),
         true <- file_mode(stat) == @private_directory_mode,
         :ok <- sync_directory(path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    else
      {:error, :eexist} -> ensure_existing_created_directory(path)
      {:error, reason} -> {:error, {path, reason}}
      false -> {:error, {:directory_mode_not_private, path}}
    end
  end

  defp ensure_existing_created_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} -> ensure_safe_ancestor(path, stat)
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink_not_allowed, path}}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_directory, path, type}}
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp ensure_safe_ancestor(path, %File.Stat{type: :directory} = stat) do
    if group_or_other_writable?(stat) and not trusted_sticky_temp?(path, stat) do
      {:error, {:writable_storage_ancestor, path}}
    else
      :ok
    end
  end

  defp ensure_private_root(path, opts) do
    repair? = Keyword.get(opts, :repair, false)

    with {:ok, %File.Stat{type: :directory} = stat} <- File.lstat(path),
         :ok <- ensure_owned_by_current_user(path, stat),
         :ok <- maybe_chmod(path, repair?),
         {:ok, %File.Stat{type: :directory} = verified_stat} <- File.lstat(path),
         true <- file_mode(verified_stat) == @private_directory_mode do
      :ok
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_directory, path, type}}
      {:error, reason} -> {:error, {path, reason}}
      false -> {:error, {:directory_mode_not_private, path}}
    end
  end

  defp ensure_ledger_file(path, opts) do
    allow_absent? = Keyword.get(opts, :allow_absent, false)
    repair? = Keyword.get(opts, :repair, false)

    case File.lstat(path) do
      {:error, :enoent} when allow_absent? ->
        :ok

      {:error, :enoent} ->
        {:error, {:ledger_file_missing, path}}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:symlink_not_allowed, path}}

      {:ok, %File.Stat{type: :regular} = stat} ->
        with :ok <- ensure_owned_by_current_user(path, stat),
             :ok <- ensure_single_link(path, stat),
             :ok <- maybe_chmod(path, repair?),
             {:ok, %File.Stat{type: :regular} = verified_stat} <- File.lstat(path),
             :ok <- ensure_single_link(path, verified_stat),
             true <- file_mode(verified_stat) == @private_file_mode do
          :ok
        else
          false -> {:error, {:ledger_file_not_private, path}}
          {:error, {:hard_link_not_allowed, _path}} = error -> error
          {:error, {:storage_not_owned, _path}} = error -> error
          {:error, reason} -> {:error, {path, reason}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_a_regular_file, path, type}}

      {:error, reason} ->
        {:error, {path, reason}}
    end
  end

  defp maybe_chmod(_path, false), do: :ok
  defp maybe_chmod(path, true), do: File.chmod(path, mode_for_path(path))

  defp mode_for_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> @private_directory_mode
      _ -> @private_file_mode
    end
  end

  defp ensure_owned_by_current_user(path, %File.Stat{uid: uid}) do
    case current_uid() do
      {:ok, ^uid} -> :ok
      {:ok, _other_uid} -> {:error, {:storage_not_owned, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_single_link(_path, %File.Stat{links: 1}), do: :ok
  defp ensure_single_link(path, %File.Stat{}), do: {:error, {:hard_link_not_allowed, path}}

  defp current_uid do
    case File.stat(System.user_home!()) do
      {:ok, %File.Stat{uid: uid}} when is_integer(uid) -> {:ok, uid}
      {:error, reason} -> {:error, {:current_uid_unavailable, reason}}
    end
  end

  defp directory_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.major_device, stat.minor_device, stat.inode}}

      {:ok, _stat} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_and_close_directory(device, path) do
    sync_result = :file.sync(device)
    close_result = :file.close(device)

    case {sync_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close_result} -> {:error, {path, reason}}
      {_sync_result, {:error, reason}} -> {:error, {path, reason}}
    end
  end

  defp regular_file_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, {stat.major_device, stat.minor_device, stat.inode}}

      {:ok, _stat} ->
        {:error, :not_a_regular_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_absolute_path(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp group_or_other_writable?(stat), do: band(file_mode_bits(stat), 0o022) != 0
  defp file_mode(stat), do: band(file_mode_bits(stat), 0o777)
  defp file_mode_bits(%File.Stat{mode: mode}), do: mode

  defp trusted_sticky_temp?(path, stat) do
    path in ["/tmp", "/private/tmp"] and stat.uid == 0 and band(file_mode_bits(stat), 0o1000) != 0
  end
end
