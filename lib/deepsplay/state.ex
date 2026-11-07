defmodule Deepsplay.State do
  @moduledoc """
  Shared state for pages (ADR 21): small JSON values per namespace, the same
  for every screen and page of a namespace, kept across restarts.

  The namespace comes from the configuration (`namespace/2`): by default its
  content root (repository, ref and `subdir`, or a local path), a named one
  with `state = "<name>"`, or none with `state = false` or
  `shared_state = false`.

  Every key has a version, unique within its namespace and increasing with
  every write, so a key deleted and created again never repeats a version.
  Values are kept as encoded JSON.

  Reads come from a table; writes go through this process, which checks
  conditions and limits and saves each changed namespace to `state_dir` at
  most a second later (one JSON file per namespace, written to a temporary
  file and renamed). Without a usable directory the store works in memory
  only.
  """

  use GenServer

  require Logger

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl

  @max_key 200
  @max_value 64 * 1024
  @max_keys 1_000
  @max_size 5 * 1024 * 1024
  @flush_after 1_000

  @type namespace :: String.t()
  @type version :: pos_integer()
  @type error ::
          :invalid_key | :invalid_json | :precondition | :too_large | :full | :not_a_number

  @doc """
  The namespace of a configuration, or `nil` if it has no shared state.
  """
  @spec namespace(HostConfig.t(), Config.t()) :: namespace() | nil
  def namespace(%HostConfig{shared_state: false}, _config), do: nil
  def namespace(_host_config, %Config{state: false}), do: nil
  def namespace(_host_config, %Config{state: name}) when is_binary(name), do: "name:" <> name

  def namespace(_host_config, %Config{path: path, subdir: subdir}) when is_binary(path),
    do: "path:" <> Path.join(path, subdir)

  def namespace(_host_config, %Config{repo: repo, ref: ref, subdir: subdir}),
    do: "repo:#{RepoUrl.key(repo)}@#{ref}/#{subdir}"

  @doc """
  Returns true for a valid key: 1 to #{@max_key} characters, segments of
  letters, digits, `.`, `_` and `-` separated by `/`, no empty segments and
  none starting with `.`.

      iex> Deepsplay.State.valid_key?("life/generation")
      true

      iex> Deepsplay.State.valid_key?("life//x")
      false

      iex> Deepsplay.State.valid_key?(".hidden")
      false
  """
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) in 1..@max_key,
    do: Regex.match?(~r{^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$}, key)

  def valid_key?(_key), do: false

  @doc false
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  The value of a key as encoded JSON, with its version.
  """
  @spec get(namespace(), String.t(), atom()) :: {:ok, binary(), version()} | :error
  def get(namespace, key, store \\ __MODULE__) do
    case :ets.lookup(store, {namespace, key}) do
      [{_id, json, version}] -> {:ok, json, version}
      [] -> :error
    end
  end

  @doc """
  Keys below `prefix` (`""` for all) with their versions, sorted.
  """
  @spec list(namespace(), String.t(), atom()) :: [{String.t(), version()}]
  def list(namespace, prefix \\ "", store \\ __MODULE__) do
    store
    |> :ets.match({{namespace, :"$1"}, :_, :"$2"})
    |> Enum.filter(fn [key, _version] -> String.starts_with?(key, prefix) end)
    |> Enum.map(fn [key, version] -> {key, version} end)
    |> Enum.sort()
  end

  @doc """
  Stores a JSON value (encoded). Options:

    * `:if_match` - only if the key has this version
    * `:if_none_match` - `true`: only if the key does not exist
  """
  @spec put(namespace(), String.t(), binary(), keyword(), atom()) ::
          {:ok, version()} | {:error, error()}
  def put(namespace, key, json, opts \\ [], store \\ __MODULE__) do
    with :ok <- check_key(key),
         {:ok, value} <- decode(json) do
      GenServer.call(store, {:put, namespace, key, value, opts})
    end
  end

  @doc """
  Deletes a key; `:if_match` as for `put/5`. Deleting a missing key is fine.
  """
  @spec delete(namespace(), String.t(), keyword(), atom()) :: :ok | {:error, error()}
  def delete(namespace, key, opts \\ [], store \\ __MODULE__) do
    with :ok <- check_key(key), do: GenServer.call(store, {:delete, namespace, key, opts})
  end

  @doc """
  Adds `by` to a number atomically; a missing key counts as 0. Returns the
  new value and version.
  """
  @spec increment(namespace(), String.t(), number(), atom()) ::
          {:ok, number(), version()} | {:error, error()}
  def increment(namespace, key, by, store \\ __MODULE__) when is_number(by) do
    with :ok <- check_key(key), do: GenServer.call(store, {:increment, namespace, key, by})
  end

  @doc """
  All namespaces with their number of keys, size in bytes and last write.
  """
  @spec namespaces(atom()) :: [
          %{
            namespace: namespace(),
            keys: non_neg_integer(),
            size: non_neg_integer(),
            written_at: DateTime.t() | nil
          }
        ]
  def namespaces(store \\ __MODULE__), do: GenServer.call(store, :namespaces)

  @doc false
  # Saves all changes now; for tests and shutdown.
  def flush(store \\ __MODULE__), do: GenServer.call(store, :flush)

  @doc false
  # Forgets everything, on disk too; for tests.
  def clear(store \\ __MODULE__), do: GenServer.call(store, :clear)

  defp check_key(key), do: if(valid_key?(key), do: :ok, else: {:error, :invalid_key})

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  # Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.fetch!(opts, :name)
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])
    dir = Keyword.get_lazy(opts, :dir, &default_dir/0)
    dir = if dir && usable?(dir), do: dir

    state = %{table: table, dir: dir, namespaces: %{}, dirty: MapSet.new(), timer: nil}
    {:ok, load(state)}
  end

  defp default_dir do
    case Store.get() do
      {:ok, host_config} ->
        if Application.get_env(:deepsplay, :persist_state, true), do: host_config.state_dir

      {:error, _errors} ->
        nil
    end
  end

  defp usable?(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning(
          "shared state: not kept on disk, #{dir} unusable: #{:file.format_error(reason)}"
        )

        false
    end
  end

  @impl true
  def handle_call({:put, namespace, key, value, opts}, _from, state) do
    current = get(namespace, key, state.table)

    with :ok <- check_condition(current, opts) do
      store(state, namespace, key, value, current)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, namespace, key, opts}, _from, state) do
    current = get(namespace, key, state.table)

    case {check_condition(current, opts), current} do
      {:ok, {:ok, json, _version}} ->
        :ets.delete(state.table, {namespace, key})
        state = update_namespace(state, namespace, -1, -entry_size(key, json), nil)
        {:reply, :ok, changed(state, namespace)}

      {:ok, :error} ->
        {:reply, :ok, state}

      {error, _current} ->
        {:reply, error, state}
    end
  end

  def handle_call({:increment, namespace, key, by}, _from, state) do
    current = get(namespace, key, state.table)

    old =
      case current do
        {:ok, json, _version} -> Jason.decode!(json)
        :error -> 0
      end

    if is_number(old) do
      case store(state, namespace, key, old + by, current) do
        {:reply, {:ok, version}, state} -> {:reply, {:ok, old + by, version}, state}
        error_reply -> error_reply
      end
    else
      {:reply, {:error, :not_a_number}, state}
    end
  end

  def handle_call(:namespaces, _from, state) do
    namespaces =
      for {namespace, info} <- Enum.sort(state.namespaces), info.keys > 0 do
        %{namespace: namespace, keys: info.keys, size: info.size, written_at: info.written_at}
      end

    {:reply, namespaces, state}
  end

  def handle_call(:flush, _from, state), do: {:reply, :ok, flush_now(state)}

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    if state.dir, do: for(file <- File.ls!(state.dir), do: File.rm(Path.join(state.dir, file)))
    {:reply, :ok, %{state | namespaces: %{}, dirty: MapSet.new()}}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush_now(%{state | timer: nil})}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: flush_now(state)

  defp check_condition(current, opts) do
    version =
      case current do
        {:ok, _json, version} -> version
        :error -> nil
      end

    cond do
      opts[:if_none_match] == true and version != nil -> {:error, :precondition}
      Keyword.has_key?(opts, :if_match) and version != opts[:if_match] -> {:error, :precondition}
      true -> :ok
    end
  end

  defp store(state, namespace, key, value, current) do
    json = Jason.encode!(value)
    info = Map.get(state.namespaces, namespace, empty_namespace())

    {old_keys, old_size} =
      case current do
        {:ok, old, _version} -> {1, entry_size(key, old)}
        :error -> {0, 0}
      end

    size = info.size - old_size + entry_size(key, json)
    keys = info.keys - old_keys + 1

    cond do
      byte_size(json) > @max_value ->
        {:reply, {:error, :too_large}, state}

      keys > @max_keys or size > @max_size ->
        {:reply, {:error, :full}, state}

      true ->
        version = info.seq + 1
        :ets.insert(state.table, {{namespace, key}, json, version})
        state = update_namespace(state, namespace, keys - info.keys, size - info.size, version)
        {:reply, {:ok, version}, changed(state, namespace)}
    end
  end

  defp entry_size(key, json), do: byte_size(key) + byte_size(json)

  defp empty_namespace, do: %{seq: 0, keys: 0, size: 0, written_at: nil}

  defp update_namespace(state, namespace, keys, size, seq) do
    info = Map.get(state.namespaces, namespace, empty_namespace())

    info = %{
      info
      | keys: info.keys + keys,
        size: info.size + size,
        seq: seq || info.seq,
        written_at: DateTime.utc_now()
    }

    put_in(state.namespaces[namespace], info)
  end

  defp changed(%{dir: nil} = state, _namespace), do: state

  defp changed(state, namespace) do
    state = %{state | dirty: MapSet.put(state.dirty, namespace)}

    if state.timer,
      do: state,
      else: %{state | timer: Process.send_after(self(), :flush, @flush_after)}
  end

  # Persistence: one file per namespace, named by a hash of it.

  defp file(dir, namespace) do
    hash = :crypto.hash(:sha256, namespace) |> Base.url_encode64(padding: false)
    Path.join(dir, hash <> ".json")
  end

  defp flush_now(%{dir: nil} = state), do: state

  defp flush_now(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Enum.each(state.dirty, &write(state, &1))
    %{state | dirty: MapSet.new(), timer: nil}
  end

  defp write(state, namespace) do
    path = file(state.dir, namespace)
    entries = :ets.match(state.table, {{namespace, :"$1"}, :"$2", :"$3"})

    if entries == [] do
      File.rm(path)
    else
      info = state.namespaces[namespace]

      document = %{
        "namespace" => namespace,
        "seq" => info.seq,
        "written_at" => info.written_at,
        "keys" =>
          Map.new(entries, fn [key, json, version] ->
            {key, %{"value" => Jason.Fragment.new(json), "version" => version}}
          end)
      }

      tmp = path <> ".tmp"

      with :ok <- File.write(tmp, Jason.encode_to_iodata!(document, pretty: true)),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp)
          Logger.warning("shared state: cannot write #{path}: #{:file.format_error(reason)}")
      end
    end
  end

  defp load(%{dir: nil} = state), do: state

  defp load(state) do
    state.dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reduce(state, fn file, state ->
      path = Path.join(state.dir, file)

      case read(path) do
        {:ok, namespace, seq, written_at, keys} ->
          for {key, json, version} <- keys,
              do: :ets.insert(state.table, {{namespace, key}, json, version})

          size =
            keys |> Enum.map(fn {key, json, _version} -> entry_size(key, json) end) |> Enum.sum()

          info = %{seq: seq, keys: length(keys), size: size, written_at: written_at}
          put_in(state.namespaces[namespace], info)

        :error ->
          Logger.warning("shared state: cannot read #{path}, ignored")
          state
      end
    end)
  end

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"namespace" => namespace, "seq" => seq, "keys" => keys} = document}
         when is_binary(namespace) and is_integer(seq) and is_map(keys) <- Jason.decode(text) do
      entries =
        for {key, %{"value" => value, "version" => version}} <- keys,
            valid_key?(key) and is_integer(version),
            do: {key, Jason.encode!(value), version}

      written_at =
        case DateTime.from_iso8601(document["written_at"] || "") do
          {:ok, time, _offset} -> time
          _other -> nil
        end

      {:ok, namespace, seq, written_at, entries}
    else
      _other -> :error
    end
  end
end
