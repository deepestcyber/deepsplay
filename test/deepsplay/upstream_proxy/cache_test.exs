defmodule Deepsplay.UpstreamProxy.CacheTest do
  use ExUnit.Case, async: true

  alias Deepsplay.UpstreamProxy.Cache
  alias Deepsplay.UpstreamProxy.Cache.Disk

  @ttls %{ttl: 60_000, stale_ttl: nil}

  setup %{test: test} do
    dir = Path.join(System.tmp_dir!(), "deepsplay-cache-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: :"cache_#{:erlang.phash2(test)}"}
  end

  defp start_cache(opts) do
    start_supervised!({Cache, opts}, id: opts[:name])
    opts[:name]
  end

  defp fetch(cache, key, value, ttls \\ @ttls),
    do: Cache.fetch(key, ttls, 1_000, fn -> {:cache, value} end, cache)

  defp body(bytes), do: :binary.copy("x", bytes)

  test "drops the least recently used entries when full", %{name: name} do
    size = :erlang.external_size(body(1_000))
    cache = start_cache(name: name, dir: nil, max_size: 2 * size + 10)

    assert {:miss, _} = fetch(cache, :a, body(1_000))
    assert {:miss, _} = fetch(cache, :b, body(1_000))
    # Using :a makes :b the least recently used one.
    assert {:hit, _, _} = fetch(cache, :a, body(1_000))
    assert {:miss, _} = fetch(cache, :c, body(1_000))

    assert {:hit, _, _} = fetch(cache, :a, "other")
    assert {:hit, _, _} = fetch(cache, :c, "other")
    assert {:miss, "other"} = fetch(cache, :b, "other")
    assert Cache.size(cache).size <= 2 * size + 10
  end

  test "does not keep values larger than the limit", %{name: name} do
    cache = start_cache(name: name, dir: nil, max_size: 100)

    assert {:miss, _} = fetch(cache, :big, body(1_000))
    assert {:miss, "small"} = fetch(cache, :big, "small")
    assert {:hit, "small", _} = fetch(cache, :big, "again")
  end

  test "keeps entries on disk across restarts", %{name: name, dir: dir} do
    cache = start_cache(name: name, dir: dir, max_size: 1_000_000)
    assert {:miss, "kept"} = fetch(cache, {:up, "/a"}, "kept")
    Cache.sync(cache)
    stop_supervised!(name)

    cache = start_cache(name: name, dir: dir, max_size: 1_000_000)
    assert {:hit, "kept", _age} = fetch(cache, {:up, "/a"}, "new")
  end

  test "loaded entries keep their times", %{name: name, dir: dir} do
    now = System.system_time(:millisecond)

    write = fn key, fetched, expires, keep ->
      record = %{
        key: key,
        value: "#{key}",
        fetched: now + fetched,
        expires: now + expires,
        keep: now + keep
      }

      File.mkdir_p!(dir)
      File.write!(Disk.path(dir, key), :erlang.term_to_binary(record))
    end

    write.(:fresh, -5_000, 55_000, 55_000)
    write.(:stale, -120_000, -60_000, 60_000)
    write.(:gone, -120_000, -60_000, -1_000)

    cache = start_cache(name: name, dir: dir, max_size: 1_000_000)
    failed = fn -> {:failed, :down} end

    assert {:hit, "fresh", age} = fetch(cache, :fresh, "new")
    assert age >= 5_000
    assert {:stale, "stale", _age} = Cache.fetch(:stale, @ttls, 1_000, failed, cache)
    assert {:miss, :down} = Cache.fetch(:gone, @ttls, 1_000, failed, cache)

    Cache.sync(cache)
    refute File.exists?(Disk.path(dir, :gone))
  end

  test "works in memory when the directory is unusable", %{name: name, dir: dir} do
    File.write!(dir, "a file, not a directory")

    {cache, log} =
      ExUnit.CaptureLog.with_log(fn -> start_cache(name: name, dir: dir, max_size: 1_000) end)

    assert log =~ "not kept on disk"
    assert {:miss, "v"} = fetch(cache, :k, "v")
    assert {:hit, "v", _age} = fetch(cache, :k, "other")
  end

  describe "refresh" do
    defp counting(test) do
      counter = :counters.new(1, [])

      fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(test, {:fetched, n})
        {:cache, n}
      end
    end

    # Receives fetch messages until none arrives for `quiet` milliseconds.
    defp drain(quiet, count \\ 0) do
      receive do
        {:fetched, _n} -> drain(quiet, count + 1)
      after
        quiet -> count
      end
    end

    test "fetches requested entries again before they expire, then stops", %{name: name} do
      cache = start_cache(name: name, dir: nil, max_size: 1_000_000)
      ttls = %{ttl: 200, stale_ttl: nil, refresh: true}
      fun = counting(self())

      assert {:miss, 1} = Cache.fetch(:k, ttls, 1_000, fun, cache)
      assert_receive {:fetched, 1}
      assert_receive {:fetched, 2}, 1_000
      assert {:hit, _n, _age} = Cache.fetch(:k, ttls, 1_000, fun, cache)

      # Without further requests, refreshes stop within three times cache_ttl.
      refreshes = drain(500)
      assert refreshes in 1..5
      refute_receive {:fetched, _n}, 300
    end

    test "does not refresh without the option", %{name: name} do
      cache = start_cache(name: name, dir: nil, max_size: 1_000_000)
      fun = counting(self())

      assert {:miss, 1} = Cache.fetch(:k, %{ttl: 100, stale_ttl: nil}, 1_000, fun, cache)
      assert_receive {:fetched, 1}
      refute_receive {:fetched, _n}, 300
    end

    test "entries loaded from disk join on their first request", %{name: name, dir: dir} do
      now = System.system_time(:millisecond)
      record = %{key: :k, value: 0, fetched: now, expires: now + 200, keep: now + 200}
      File.mkdir_p!(dir)
      File.write!(Disk.path(dir, :k), :erlang.term_to_binary(record))

      cache = start_cache(name: name, dir: dir, max_size: 1_000_000)
      ttls = %{ttl: 200, stale_ttl: nil, refresh: true}

      assert {:hit, 0, _age} = Cache.fetch(:k, ttls, 1_000, counting(self()), cache)
      assert_receive {:fetched, 1}, 1_000
    end
  end

  test "deletes unreadable files and those past their stale time", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "broken.entry"), "not a term")

    old = %{key: :old, value: "v", fetched: 0, expires: 1, keep: 2}
    File.write!(Disk.path(dir, :old), :erlang.term_to_binary(old))

    assert Disk.load(dir) |> Enum.map(& &1.key) == [:old]
    refute File.exists?(Path.join(dir, "broken.entry"))
  end
end
