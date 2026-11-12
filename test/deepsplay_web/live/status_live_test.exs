defmodule DeepsplayWeb.StatusLiveTest do
  # Not async: uses the global host configuration, status and presence.
  use DeepsplayWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Deepsplay.ScreenFixture

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Revisions
  alias DeepsplayWeb.Presence

  @moduletag :tmp_dir

  @files %{
    "screen.toml" => ~s(title = "Lobby"\n[backend]\n[[page]]\npath = "a.html"\nduration = "1s"\n),
    "pages/a.html" => "a"
  }

  setup %{tmp_dir: tmp_dir} do
    setup_screen(tmp_dir, @files, """
    [[config]]
    name = "kitchen"
    repo = "file:///nonexistent/kitchen"
    ref  = "main"
    """)
  end

  test "lists configurations with revision, warnings and errors", ctx do
    {:ok, sha} = Revisions.refresh(ctx.config)
    {:ok, host_config} = Store.get()
    capture_log(fn -> Revisions.refresh(host_config.configs["kitchen"]) end)

    {:ok, view, _html} = live(ctx.conn, ~p"/status")

    assert has_element?(view, "#config-lobby", String.slice(sha, 0, 12))
    assert has_element?(view, "#config-lobby", "Lobby")
    assert has_element?(view, "#config-lobby", "default")
    assert has_element?(view, "#config-lobby .config-warning", "[backend] is ignored")
    assert has_element?(view, "#config-kitchen", "none yet")
    assert has_element?(view, "#config-kitchen .config-error", "fetch failed")
    assert has_element?(view, "#status-errors .error-entry", "kitchen")
  end

  test "shows when the host configuration was loaded", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/status")
    refute has_element?(view, "#status-host-config")

    start_supervised!({Deepsplay.HostConfig.Watcher, interval: 60_000, signals: false})
    {:ok, view, _html} = live(build_conn(), ~p"/status")
    assert has_element?(view, "#status-host-config", "Host configuration loaded")
    refute has_element?(view, "#status-host-config-rejected")
  end

  test "updates when a revision is published", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/status")
    assert has_element?(view, "#config-lobby", "none yet")

    {:ok, _sha} = Revisions.refresh(ctx.config)
    assert has_element?(view, "#config-lobby", "Lobby")

    new = GitFixture.commit(ctx.src, %{"pages/a.html" => "b"})
    {:ok, ^new} = Revisions.refresh(ctx.config)
    assert has_element?(view, "#config-lobby", String.slice(new, 0, 12))
  end

  test "shows connected screens with their state and page", ctx do
    {:ok, sha} = Revisions.refresh(ctx.config)
    Phoenix.PubSub.subscribe(Deepsplay.PubSub, Presence.topic())

    {:ok, status, _html} = live(ctx.conn, ~p"/status")
    assert has_element?(status, "#status-screens", "No screen is connected")

    {:ok, screen, _html} = live(build_conn(), ~p"/?screen=hall")
    await_diff(fn diff -> joined?(diff, &(&1.label == "hall")) end)

    assert has_element?(status, "#status-screens tr", "hall")
    assert has_element?(status, "#status-screens tr", "playing")
    assert has_element?(status, "#status-screens tr", String.slice(sha, 0, 12))

    render_hook(screen, "page", %{"url" => "/c/lobby/r/#{sha}/a.html?duration=1s"})
    await_diff(fn diff -> joined?(diff, &(&1.page == "a.html?duration=1s")) end)
    assert has_element?(status, "#status-screens tr", "a.html?duration=1s")

    GenServer.stop(screen.pid)

    await_diff(fn diff ->
      Enum.any?(diff.leaves, fn {_id, %{metas: m}} -> Enum.any?(m, &(&1.label == "hall")) end)
    end)

    assert has_element?(status, "#status-screens", "No screen is connected")
  end

  test "a screen behind a trusted proxy shows its own address", ctx do
    {:ok, _sha} = Revisions.refresh(ctx.config)
    Phoenix.PubSub.subscribe(Deepsplay.PubSub, Presence.topic())

    previous = DeepsplayWeb.TrustedProxies.ranges()
    on_exit(fn -> :persistent_term.put({DeepsplayWeb.TrustedProxies, :proxies}, previous) end)
    DeepsplayWeb.TrustedProxies.setup!("10.0.0.2")

    {:ok, status, _html} = live(ctx.conn, ~p"/status")

    for {peer, label} <- [{{10, 0, 0, 2}, "proxied"}, {{10, 0, 0, 3}, "direct"}] do
      conn =
        put_private(build_conn(), :live_view_connect_info, %{
          peer_data: %{address: peer, port: 50_000, ssl_cert: nil},
          x_headers: [{"x-forwarded-for", "192.168.1.20"}]
        })

      {:ok, _screen, _html} = live(conn, ~p"/?screen=#{label}")
      await_diff(fn diff -> joined?(diff, &(&1.label == label)) end)
    end

    assert has_element?(status, "#status-screens tr", "proxied")
    assert has_element?(status, "#status-screens tr", "192.168.1.20")
    assert has_element?(status, "#status-screens tr", "10.0.0.3")
    refute has_element?(status, "#status-screens tr", "10.0.0.2")
  end

  # Presence diffs from screens of earlier tests can still arrive; wait for
  # the one this test caused. The status page received it too, before any
  # later render.
  defp await_diff(matches?) do
    receive do
      %Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff} ->
        if matches?.(diff), do: :ok, else: await_diff(matches?)
    after
      3_000 -> flunk("expected presence diff did not arrive")
    end
  end

  defp joined?(diff, meta?) do
    Enum.any?(diff.joins, fn {_id, %{metas: metas}} -> Enum.any?(metas, meta?) end)
  end

  test "shows the app version", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/status")

    version = Application.spec(:deepsplay, :vsn) |> to_string()
    assert has_element?(view, "#status-version", "deepsplay #{version}")
  end

  test "shows an unusable host configuration", %{conn: conn} do
    Store.put({:error, ["server.cache_dir is missing"]})

    {:ok, view, _html} = live(conn, ~p"/status")
    assert has_element?(view, "#status-host-config-error", "server.cache_dir is missing")
  end
end
