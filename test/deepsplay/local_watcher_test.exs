defmodule Deepsplay.LocalWatcherTest do
  # Not async: uses the global host configuration, status and file watching.
  use DeepsplayWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.LocalWatcher
  alias Deepsplay.Pollers
  alias Deepsplay.Revisions
  alias Deepsplay.Status

  @moduletag :tmp_dir

  @manifest ~s(title = "Local"\n[[page]]\npath = "a.html?duration=5s"\nduration = "5s"\n)

  defp write(root, files) do
    for {path, content} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "screens")
    write(root, %{"screen.toml" => @manifest, "pages/a.html" => "v1", "README.md" => "x"})

    {:ok, host_config} =
      HostConfig.parse("""
      [server]
      cache_dir      = "#{Path.join(tmp_dir, "cache")}"
      default_config = "local"

      [[config]]
      name = "local"
      path = "#{root}"
      """)

    previous = Store.get()
    Store.put({:ok, host_config})
    Status.clear()
    on_exit(fn -> Store.put(previous) end)

    config = host_config.configs["local"]
    Revisions.subscribe("local")
    start_supervised!({LocalWatcher, config})
    assert_receive {:revision_published, "local", _initial}, 2_000
    token = await_watching(root)

    %{root: root, config: config, token: token}
  end

  # inotify starts watching shortly after the watcher starts; until then,
  # changes go unseen. Touch a probe file until a change is noticed, then
  # wait out the debounce, so tests start with a quiet, watching watcher.
  # Probes are spaced wider than the watcher's 200 ms debounce, which every
  # write restarts.
  defp await_watching(root, attempts \\ 10) do
    write(root, %{"pages/probe.html" => "#{attempts}"})

    receive do
      {:revision_published, "local", token} ->
        flush_until_quiet(token)
    after
      500 ->
        if attempts > 0, do: await_watching(root, attempts - 1), else: flunk("not watching")
    end
  end

  defp flush_until_quiet(token) do
    receive do
      {:revision_published, "local", newer} -> flush_until_quiet(newer)
      {:status_changed, "local"} -> flush_until_quiet(token)
    after
      400 -> token
    end
  end

  test "serves the directory live under a version token", %{
    root: root,
    config: config,
    token: token
  } do
    assert {:ok, ^token} = LocalWatcher.token("local")
    assert {:ok, %{sha: ^token, local: true, pages_dir: pages_dir}} = Revisions.current(config)
    assert pages_dir == Path.join(root, "pages")
    assert String.length(token) == 40
  end

  test "a change in pages/ or the manifest gives a new token", %{root: root, token: token} do
    write(root, %{"pages/a.html" => "v2"})
    assert_receive {:revision_published, "local", second}, 2_000
    refute second == token

    write(root, %{"screen.toml" => @manifest <> "# changed\n"})
    assert_receive {:revision_published, "local", third}, 2_000
    refute third == second
  end

  test "a burst of changes gives one new token", %{root: root} do
    for n <- 1..5, do: write(root, %{"pages/a.html" => "v#{n}"})

    assert_receive {:revision_published, "local", _}, 2_000
    refute_receive {:revision_published, "local", _}, 500
  end

  test "changes outside pages/ and hidden files are ignored", %{root: root} do
    write(root, %{"README.md" => "changed", "pages/.swap" => "x", "other/x.txt" => "x"})
    refute_receive {:revision_published, "local", _}, 700
  end

  test "an invalid manifest is reported and shown", %{conn: conn, root: root} do
    capture_log(fn ->
      write(root, %{"screen.toml" => "[[page]]\n"})
      assert_receive {:revision_published, "local", _}, 2_000
    end)

    assert Status.get("local").error =~ "page #1.path is missing"

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#fallback-revision-error")
    assert has_element?(view, "#fallback-path")
  end

  test "files are served live and not cached", %{conn: conn, root: root, token: token} do
    conn = get(conn, "/c/local/r/#{token}/a.html")
    assert response(conn, 200) == "v1"
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    File.write!(Path.join(root, "pages/a.html"), "v2")
    assert build_conn() |> get("/c/local/r/#{token}/a.html") |> response(200) == "v2"

    assert build_conn() |> get("/c/local/r/#{token}/../README.md") |> response(404)
    assert build_conn() |> get("/c/local/r/#{token}/screen.toml") |> response(404)
  end

  test "the screen gets plans that apply at once", %{conn: conn, root: root, token: token} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert_push_event(view, "plan", %{sha: ^token, apply: "now"})

    write(root, %{"pages/a.html" => "v2"})
    assert_receive {:revision_published, "local", second}, 2_000
    assert_push_event(view, "plan", %{sha: ^second, apply: "now", pages: [%{url: url}]})
    assert url == "/c/local/r/#{second}/a.html?duration=5s"
  end

  test "Pollers starts a watcher for local configurations", %{config: config} do
    {:ok, host_config} = Store.get()
    assert [{LocalWatcher, ^config}] = Pollers.child_specs(host_config)
  end
end
