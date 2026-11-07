defmodule Deepsplay.UpstreamProxy.Cache do
  @moduledoc """
  Cache of upstream answers (ADR 8, ADR 20), so many screens share one
  upstream call within an upstream's `cache_ttl`.

  Requests are coalesced: per key at most one fetch runs. Requests for the
  same key arriving meanwhile wait for it and get its result; they never start
  fetches of their own. Only results the fetch marks as cacheable are kept.
  Fetches run in tasks of `Deepsplay.UpstreamProxy.Tasks`, attributed to the
  request that started them (`$callers`).

  With a `stale_ttl`, an entry is kept that long after it expired. An expired
  entry is fetched again on the next request; if that fetch fails, crashes or
  takes longer than the request may wait, the stale value is served instead.

  The cache is limited in size (`upstream_cache_size`); when full, the least
  recently used entries are dropped. A group of entries (one upstream) can
  have a limit of its own (`cache_size`, ADR 22): beyond it, the group's own
  least recently used entries go first. Entries are also kept on disk in
  `<cache_dir>/.upstream/` (hidden, so the cache cleanup leaves it alone) and
  loaded again on start. Entries past their `stale_ttl` are swept once a
  minute.

  With `refresh`, an entry is fetched again shortly before it expires, as
  long as it was requested within the last three times its `cache_ttl`, so
  screens get cache hits and the upstream sees one call per `cache_ttl`.
  Entries loaded from disk join the refresh on their first request.
  """

  use GenServer

  require Logger

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.UpstreamProxy.Cache.Disk

  @tasks Deepsplay.UpstreamProxy.Tasks
  @sweep 60_000
  @default_size 200_000_000

  @typedoc """
  What a fetch function returns: a value to cache, one to pass on only, or a
  failure, which a stale value replaces if there is one.
  """
  @type fetched :: {:cache, term()} | {:no_cache, term()} | {:failed, term()}

  @typedoc """
  How long to keep a fetched value, in milliseconds, whether to refresh it
  before it expires, a label grouping entries for `groups/1`, and the most
  the entries of that group may take (ADR 22).
  """
  @type ttls :: %{
          required(:ttl) => pos_integer(),
          required(:stale_ttl) => non_neg_integer() | nil,
          optional(:refresh) => boolean(),
          optional(:group) => term(),
          optional(:max_size) => pos_integer() | nil
        }

  @type result ::
          {:hit | :stale, term(), non_neg_integer()}
          | {:miss, term()}
          | {:error, :timeout | :crashed}

  @doc """
  Starts the cache.

  Options, defaulting to the host configuration:

    * `:name` - process and table name, default `#{inspect(__MODULE__)}`
    * `:dir` - directory for entries on disk, or `nil` for none
    * `:max_size` - size limit in bytes
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Returns the cached value for `key`, or runs `fun` to fetch it, coalesced
  with concurrent requests for the same key.

  A `{:cache, value}` from `fun` is kept for `ttls.ttl` milliseconds, and as
  stale value for `ttls.stale_ttl` after that. With `ttls.refresh`, `fun` is
  kept to fetch the value again before it expires. Waits at most `timeout`
  milliseconds for a running fetch.

  Returns `{:hit, value, age_ms}` for a fresh entry, `{:miss, value}` with the
  fetched value, `{:stale, value, age_ms}` when the fetch failed and a stale
  value exists, or `{:error, :timeout | :crashed}`.
  """
  @spec fetch(term(), ttls(), timeout(), (-> fetched()), atom()) :: result()
  def fetch(key, ttls, timeout, fun, cache \\ __MODULE__) do
    callers = [self() | Process.get(:"$callers", [])]

    case lookup(cache, key) do
      {:fresh, value, age} ->
        touch(cache, key)

        if ttls[:refresh] == true and not :ets.lookup_element(cache, key, 9, true),
          do: GenServer.cast(cache, {:adopt, key, ttls, fun, callers})

        {:hit, value, age}

      _stale_or_miss ->
        try do
          GenServer.call(cache, {:fetch, key, ttls, fun, callers}, timeout)
        catch
          :exit, {:timeout, _call} -> stale_or(cache, key, {:error, :timeout})
        end
    end
  end

  @doc """
  Current size of all entries in bytes, and the limit.
  """
  @spec size(atom()) :: %{size: non_neg_integer(), max_size: pos_integer()}
  def size(cache \\ __MODULE__), do: GenServer.call(cache, :size)

  @doc """
  Number and size of entries per group (see `t:ttls/0`).
  """
  @spec groups(atom()) :: %{term() => %{entries: non_neg_integer(), size: non_neg_integer()}}
  def groups(cache \\ __MODULE__) do
    cache
    |> :ets.select([{{:_, :_, :_, :_, :_, :"$1", :_, :_, :_, :"$2"}, [], [{{:"$2", :"$1"}}]}])
    |> Enum.reduce(%{}, fn {group, size}, acc ->
      Map.update(acc, group, %{entries: 1, size: size}, fn totals ->
        %{entries: totals.entries + 1, size: totals.size + size}
      end)
    end)
  end

  @doc """
  Changes the size limit, dropping least recently used entries if the cache
  is above the new one (a reloaded host configuration, ADR 23).
  """
  @spec set_max_size(pos_integer(), atom()) :: :ok
  def set_max_size(max_size, cache \\ __MODULE__),
    do: GenServer.call(cache, {:max_size, max_size})

  @doc false
  # Waits until all entries are on disk; for tests.
  def sync(cache \\ __MODULE__), do: GenServer.call(cache, :sync, :infinity)

  @doc false
  # Forgets everything, on disk too; for tests.
  def clear(cache \\ __MODULE__), do: GenServer.call(cache, :clear)

  @doc false
  # Lets every entry expire, keeping stale values; for tests.
  def expire_all(cache \\ __MODULE__), do: GenServer.call(cache, :expire_all)

  # Rows: {key, value, expires, fetched, keep_until, size, last_used,
  # requested, refreshing, group}, with monotonic times and a use mark;
  # `refreshing` tells whether the cache process has a refresh for the entry,
  # `group` is the caller's label for statistics. The table is named like the
  # cache process.
  defp lookup(table, key) do
    now = now()

    case :ets.lookup(table, key) do
      [{^key, value, expires, fetched, _keep, _size, _used, _requested, _refreshing, _group}]
      when expires > now ->
        {:fresh, value, now - fetched}

      [{^key, value, _expires, fetched, keep, _size, _used, _requested, _refreshing, _group}]
      when keep > now ->
        {:stale, value, now - fetched}

      _other ->
        :miss
    end
  end

  defp touch(table, key), do: :ets.update_element(table, key, [{7, use_mark()}, {8, now()}])

  # Orders uses; unlike a clock, it never gives two uses the same value.
  defp use_mark, do: :erlang.unique_integer([:monotonic])

  defp stale_or(table, key, other) do
    case lookup(table, key) do
      :miss ->
        other

      {_fresh_or_stale, value, age} ->
        touch(table, key)
        {:stale, value, age}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.fetch!(opts, :name)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

    {dir, max_size} = settings(opts)

    disk = if dir, do: start_disk(dir)

    Process.send_after(self(), :sweep, @sweep)

    state = %{
      table: table,
      disk: disk,
      max_size: max_size,
      size: 0,
      # Size per group, for groups with a limit of their own.
      group_sizes: %{},
      # Running fetches: task ref => %{key, ttls, fun, callers, waiters};
      # key => task ref.
      fetches: %{},
      keys: %{},
      # Entries to refresh: key => %{ttls, fun, callers}.
      refresh: %{}
    }

    {:ok, state, {:continue, {:load, disk && dir}}}
  end

  # Without a usable directory the cache still works, in memory only.
  defp start_disk(dir) do
    case Disk.start_link(dir) do
      {:ok, disk} ->
        disk

      {:error, reason} ->
        Logger.warning("upstream cache: not kept on disk, #{dir} unusable: #{inspect(reason)}")
        nil
    end
  end

  defp settings(opts) do
    {cache_dir, size} =
      case Store.get() do
        {:ok, host_config} -> {host_config.cache_dir, host_config.upstream_cache_size}
        {:error, _errors} -> {nil, @default_size}
      end

    default_dir =
      if cache_dir && Application.get_env(:deepsplay, :persist_upstream_cache, true),
        do: Path.join(cache_dir, ".upstream")

    {Keyword.get(opts, :dir, default_dir), Keyword.get(opts, :max_size, size)}
  end

  @impl true
  def handle_continue({:load, nil}, state), do: {:noreply, state}

  def handle_continue({:load, dir}, state) do
    now = now()
    offset = System.time_offset(:millisecond)

    {usable, expired} =
      dir
      |> Disk.load()
      |> Enum.map(fn record ->
        %{
          record
          | fetched: record.fetched - offset,
            expires: record.expires - offset,
            keep: record.keep - offset
        }
      end)
      |> Enum.split_with(&(&1.keep > now))

    for record <- expired, do: Disk.delete(state.disk, record.key)

    # Newest first, as far as the limit allows; older ones count as less
    # recently used.
    {rows, size} =
      usable
      |> Enum.sort_by(& &1.fetched, :desc)
      |> Enum.reduce({[], 0}, fn record, {rows, total} ->
        size = entry_size(record.value)

        if total + size <= state.max_size do
          {[{record, size} | rows], total + size}
        else
          Disk.delete(state.disk, record.key)
          {rows, total}
        end
      end)

    group_sizes =
      Enum.reduce(rows, %{}, fn {record, size}, sizes ->
        group = Map.get(record, :group)

        row =
          {record.key, record.value, record.expires, record.fetched, record.keep, size,
           use_mark(), now, false, group}

        :ets.insert(state.table, row)
        Map.update(sizes, group, size, &(&1 + size))
      end)

    {:noreply, %{state | size: size, group_sizes: group_sizes}}
  end

  @impl true
  def handle_call({:fetch, key, ttls, fun, callers}, from, state) do
    :ets.update_element(state.table, key, {8, now()})

    case {lookup(state.table, key), Map.fetch(state.keys, key)} do
      {{:fresh, value, age}, _running} ->
        touch(state.table, key)
        state = if ttls[:refresh] == true, do: adopt(state, key, ttls, fun, callers), else: state
        {:reply, {:hit, value, age}, state}

      {_stale_or_miss, {:ok, ref}} ->
        {:noreply, update_in(state.fetches[ref].waiters, &[from | &1])}

      {_stale_or_miss, :error} ->
        {:noreply, start_fetch(state, key, ttls, fun, callers, [from])}
    end
  end

  def handle_call({:max_size, max_size}, _from, state),
    do: {:reply, :ok, evict(%{state | max_size: max_size})}

  def handle_call(:size, _from, state),
    do: {:reply, %{size: state.size, max_size: state.max_size}, state}

  def handle_call(:sync, _from, state) do
    if state.disk, do: Disk.sync(state.disk)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    if state.disk, do: Disk.delete_all(state.disk)
    {:reply, :ok, %{state | size: 0, group_sizes: %{}}}
  end

  def handle_call(:expire_all, _from, state) do
    now = now()

    for {key, _value, expires, _fetched, keep, _size, _used, _requested, _refreshing, _group} <-
          :ets.tab2list(state.table) do
      :ets.update_element(state.table, key, [{3, now}, {5, now + keep - expires}])
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:adopt, key, ttls, fun, callers}, state),
    do: {:noreply, adopt(state, key, ttls, fun, callers)}

  @impl true
  def handle_info({:refresh, key, expires}, state) do
    now = now()

    with %{ttls: ttls, fun: fun, callers: callers} <- state.refresh[key],
         [{^key, _value, ^expires, _fetched, _keep, _size, _used, requested, _refreshing, _group}] <-
           :ets.lookup(state.table, key),
         false <- Map.has_key?(state.keys, key) do
      if requested >= now - 3 * ttls.ttl do
        {:noreply, start_fetch(state, key, ttls, fun, callers, [])}
      else
        # Nobody asked lately: let the entry expire.
        :ets.update_element(state.table, key, {9, false})
        {:noreply, %{state | refresh: Map.delete(state.refresh, key)}}
      end
    else
      _replaced_or_running -> {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {fetch, state} = pop_fetch(state, ref)

    {reply, state} =
      case result do
        {:cache, value} -> {{:miss, value}, insert(state, fetch, value)}
        {:no_cache, value} -> {{:miss, value}, state}
        {:failed, value} -> {stale_or(state.table, fetch.key, {:miss, value}), state}
      end

    reply_all(fetch, reply)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {fetch, state} = pop_fetch(state, ref)
    if fetch, do: reply_all(fetch, stale_or(state.table, fetch.key, {:error, :crashed}))
    {:noreply, state}
  end

  def handle_info({:EXIT, disk, reason}, %{disk: disk} = state), do: {:stop, reason, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    now = now()

    expired =
      :ets.select(state.table, [
        {{:"$1", :_, :_, :_, :"$2", :_, :_, :_, :_, :_}, [{:"=<", :"$2", now}], [:"$1"]}
      ])

    state = Enum.reduce(expired, state, &delete(&2, &1))
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end

  # Writes still queued reach the disk before the cache goes.
  @impl true
  def terminate(_reason, state) do
    if state.disk, do: catch_exit(Disk.sync(state.disk))
  end

  defp catch_exit(call) do
    call
  catch
    :exit, _reason -> :ok
  end

  defp insert(state, %{key: key, ttls: ttls} = fetch, value) do
    size = entry_size(value)
    now = now()
    # A refresh keeps the time of the last request, so entries nobody asks
    # for stop being refreshed.
    requested = :ets.lookup_element(state.table, key, 8, now)
    state = delete(state, key)
    group = ttls[:group]
    group_max = ttls[:max_size]

    if size > state.max_size or (group_max != nil and size > group_max) do
      state
    else
      expires = now + ttls.ttl
      keep = expires + (ttls.stale_ttl || 0)
      refresh? = ttls[:refresh] == true
      row = {key, value, expires, now, keep, size, use_mark(), requested, refresh?, group}
      :ets.insert(state.table, row)

      state =
        update_in(state.group_sizes, &Map.update(&1, group, size, fn total -> total + size end))

      state =
        if refresh? do
          schedule_refresh(key, expires, ttls.ttl)
          refresh = %{ttls: ttls, fun: fetch.fun, callers: fetch.callers}
          put_in(state.refresh[key], refresh)
        else
          state
        end

      if state.disk do
        offset = System.time_offset(:millisecond)

        Disk.write(state.disk, %{
          key: key,
          value: value,
          fetched: now + offset,
          expires: expires + offset,
          keep: keep + offset,
          group: ttls[:group]
        })
      end

      %{state | size: state.size + size}
      |> evict_group(group, group_max)
      |> evict()
    end
  end

  # An entry without a refresh (loaded from disk) gets one.
  defp adopt(state, key, ttls, fun, callers) do
    case :ets.lookup(state.table, key) do
      [{^key, _value, expires, _fetched, _keep, _size, _used, _requested, false, _group}] ->
        :ets.update_element(state.table, key, {9, true})
        schedule_refresh(key, expires, ttls.ttl)
        put_in(state.refresh[key], %{ttls: ttls, fun: fun, callers: callers})

      _gone_or_refreshing ->
        state
    end
  end

  # Shortly before the entry expires: a tenth of its time, at most 5 seconds.
  defp schedule_refresh(key, expires, ttl) do
    lead = min(div(ttl, 10), 5_000)
    delay = max(expires - lead - now(), 0)
    Process.send_after(self(), {:refresh, key, expires}, delay)
  end

  defp start_fetch(state, key, ttls, fun, callers, waiters) do
    task =
      Task.Supervisor.async_nolink(@tasks, fn ->
        Process.put(:"$callers", callers)
        fun.()
      end)

    fetch = %{key: key, ttls: ttls, fun: fun, callers: callers, waiters: waiters}

    %{
      state
      | fetches: Map.put(state.fetches, task.ref, fetch),
        keys: Map.put(state.keys, key, task.ref)
    }
  end

  # Drops the group's least recently used entries until it fits its limit.
  defp evict_group(state, _group, nil), do: state

  defp evict_group(state, group, max) do
    if Map.get(state.group_sizes, group, 0) <= max do
      state
    else
      state.table
      |> :ets.select([
        {{:"$1", :_, :_, :_, :_, :_, :"$2", :_, :_, :"$3"}, [{:"=:=", :"$3", {:const, group}}],
         [{{:"$2", :"$1"}}]}
      ])
      |> Enum.sort()
      |> Enum.reduce_while(state, fn {_used, key}, state ->
        if Map.get(state.group_sizes, group, 0) > max,
          do: {:cont, delete(state, key)},
          else: {:halt, state}
      end)
    end
  end

  # Drops the least recently used entries until the cache fits its limit.
  defp evict(%{size: size, max_size: max} = state) when size <= max, do: state

  defp evict(state) do
    state.table
    |> :ets.select([
      {{:"$1", :_, :_, :_, :_, :"$2", :"$3", :_, :_, :_}, [], [{{:"$3", :"$1", :"$2"}}]}
    ])
    |> Enum.sort()
    |> Enum.reduce_while(state, fn {_used, key, _size}, state ->
      if state.size > state.max_size,
        do: {:cont, delete(state, key)},
        else: {:halt, state}
    end)
  end

  defp delete(state, key) do
    case :ets.take(state.table, key) do
      [{^key, _value, _expires, _fetched, _keep, size, _used, _requested, _refreshing, group}] ->
        if state.disk, do: Disk.delete(state.disk, key)

        %{
          state
          | size: state.size - size,
            group_sizes: Map.update(state.group_sizes, group, 0, &(&1 - size)),
            refresh: Map.delete(state.refresh, key)
        }

      [] ->
        state
    end
  end

  defp entry_size(value), do: :erlang.external_size(value)

  defp pop_fetch(state, ref) do
    case Map.pop(state.fetches, ref) do
      {nil, _fetches} ->
        {nil, state}

      {fetch, fetches} ->
        {fetch, %{state | fetches: fetches, keys: Map.delete(state.keys, fetch.key)}}
    end
  end

  defp reply_all(fetch, reply), do: Enum.each(fetch.waiters, &GenServer.reply(&1, reply))
end
