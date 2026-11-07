defmodule Deepsplay.StateTest do
  use ExUnit.Case, async: true

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.State

  doctest State

  @ns "repo:screens@main/"

  setup %{test: test} do
    dir = Path.join(System.tmp_dir!(), "deepsplay-state-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, name: :"state_#{:erlang.phash2(test)}"}
  end

  defp start_store(opts) do
    start_supervised!({State, opts}, id: opts[:name])
    opts[:name]
  end

  describe "namespace/2" do
    @host %HostConfig{cache_dir: "/c", default_config: "a", configs: %{}}

    test "derives it from the content root, a name, or none" do
      repo = %Config{
        name: "a",
        repo: "https://example.com/screens.git",
        ref: "main",
        subdir: "lobby"
      }

      ns = State.namespace(@host, repo)
      assert ns =~ ~r"^repo:example.com-screens-[0-9a-f]{8}@main/lobby$"

      # Other manifests of the same root share it; another ref does not.
      assert State.namespace(@host, %{repo | name: "b", manifest: "x.toml"}) == ns
      refute State.namespace(@host, %{repo | ref: "staging"}) == ns

      assert State.namespace(@host, %Config{name: "a", path: "/srv/s"}) == "path:/srv/s"
      assert State.namespace(@host, %{repo | state: "hall"}) == "name:hall"
      assert State.namespace(@host, %{repo | state: false}) == nil
      assert State.namespace(%{@host | shared_state: false}, repo) == nil
    end
  end

  test "stores, reads, lists and deletes values with versions", %{name: name} do
    store = start_store(name: name, dir: nil)

    assert State.get(@ns, "life/gen", store) == :error
    assert {:ok, 1} = State.put(@ns, "life/gen", ~s({"n": 1}), [], store)
    assert {:ok, ~s({"n":1}), 1} = State.get(@ns, "life/gen", store)
    assert {:ok, 2} = State.put(@ns, "shared/msg", ~s("hi"), [], store)
    assert {:ok, 3} = State.put(@ns, "life/gen", "2", [], store)

    assert State.list(@ns, "", store) == [{"life/gen", 3}, {"shared/msg", 2}]
    assert State.list(@ns, "life/", store) == [{"life/gen", 3}]
    assert State.list("other", "", store) == []

    assert :ok = State.delete(@ns, "life/gen", [], store)
    assert :ok = State.delete(@ns, "life/gen", [], store)
    # A key created again never repeats a version.
    assert {:ok, 4} = State.put(@ns, "life/gen", "1", [], store)
  end

  test "rejects invalid keys and JSON", %{name: name} do
    store = start_store(name: name, dir: nil)

    assert State.put(@ns, "a//b", "1", [], store) == {:error, :invalid_key}
    assert State.put(@ns, String.duplicate("a", 201), "1", [], store) == {:error, :invalid_key}
    assert State.put(@ns, "a", "{nope", [], store) == {:error, :invalid_json}
  end

  test "conditional writes", %{name: name} do
    store = start_store(name: name, dir: nil)

    assert {:ok, 1} = State.put(@ns, "k", "1", [if_none_match: true], store)
    assert State.put(@ns, "k", "2", [if_none_match: true], store) == {:error, :precondition}
    assert State.put(@ns, "k", "2", [if_match: 7], store) == {:error, :precondition}
    assert {:ok, 2} = State.put(@ns, "k", "2", [if_match: 1], store)
    assert State.delete(@ns, "k", [if_match: 1], store) == {:error, :precondition}
    assert State.put(@ns, "missing", "1", [if_match: 1], store) == {:error, :precondition}
  end

  test "increments numbers atomically", %{name: name} do
    store = start_store(name: name, dir: nil)

    assert {:ok, 1, 1} = State.increment(@ns, "visits", 1, store)

    1..20
    |> Task.async_stream(fn _ -> State.increment(@ns, "visits", 1, store) end)
    |> Stream.run()

    assert {:ok, "21", _version} = State.get(@ns, "visits", store)
    assert {:ok, 21.5, _version} = State.increment(@ns, "visits", 0.5, store)

    State.put(@ns, "text", ~s("x"), [], store)
    assert State.increment(@ns, "text", 1, store) == {:error, :not_a_number}
  end

  test "limits values, keys and namespace size", %{name: name} do
    store = start_store(name: name, dir: nil)

    big = Jason.encode!(String.duplicate("x", 64 * 1024))
    assert State.put(@ns, "big", big, [], store) == {:error, :too_large}

    for i <- 1..1_000, do: assert({:ok, _} = State.put(@ns, "k#{i}", "1", [], store))
    assert State.put(@ns, "one-more", "1", [], store) == {:error, :full}
    # Replacing a key does not add one.
    assert {:ok, _} = State.put(@ns, "k1", "2", [], store)

    value = Jason.encode!(String.duplicate("x", 60 * 1024))

    results = for i <- 1..90, do: State.put("big-ns", "v#{i}", value, [], store)
    assert {:error, :full} in results

    assert [%{namespace: "big-ns", size: size}, %{namespace: @ns, keys: 1_000}] =
             State.namespaces(store)

    assert size <= 5 * 1024 * 1024
  end

  test "keeps namespaces on disk across restarts", %{name: name, dir: dir} do
    store = start_store(name: name, dir: dir)
    {:ok, 1} = State.put(@ns, "life/gen", ~s({"n": 1}), [], store)
    {:ok, 2} = State.put(@ns, "gone", "1", [], store)
    :ok = State.delete(@ns, "gone", [], store)
    {:ok, 1} = State.put("name:hall", "msg", ~s("hi"), [], store)
    State.flush(store)
    assert length(File.ls!(dir)) == 2
    stop_supervised!(name)

    store = start_store(name: name, dir: dir)
    assert {:ok, ~s({"n":1}), 1} = State.get(@ns, "life/gen", store)
    assert State.get(@ns, "gone", store) == :error
    assert {:ok, ~s("hi"), 1} = State.get("name:hall", "msg", store)
    # Versions continue after a restart.
    assert {:ok, 3} = State.put(@ns, "life/gen", "2", [], store)
  end

  test "saves changes on its own, shortly after", %{name: name, dir: dir} do
    store = start_store(name: name, dir: dir)
    {:ok, 1} = State.put(@ns, "k", "1", [], store)
    assert File.ls!(dir) == []

    # Saved within a second; poll the directory instead of sleeping blindly.
    assert Enum.any?(1..30, fn _ ->
             receive do
             after
               100 -> File.ls!(dir) != []
             end
           end)
  end

  test "works in memory when the directory is unusable", %{name: name, dir: dir} do
    File.write!(dir, "a file")

    {store, log} =
      ExUnit.CaptureLog.with_log(fn -> start_store(name: name, dir: dir) end)

    assert log =~ "not kept on disk"
    assert {:ok, 1} = State.put(@ns, "k", "1", [], store)
  end
end
