defmodule DeepsplayWeb.StatusUpstreamsTest do
  # Not async: uses the global host configuration and proxy cache.
  use DeepsplayWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Deepsplay.ScreenFixture

  alias Deepsplay.Revisions
  alias Deepsplay.UpstreamProxy.Cache
  alias Deepsplay.UpstreamProxy.Stats

  @moduletag :tmp_dir
  @stub Deepsplay.UpstreamProxy

  @files %{
    "screen.toml" => """
    [upstream.radar]
    url       = "https://radar.example.com/wms"
    cache_ttl = "5m"
    stale_ttl = "1h"
    cache_size = "1MB"

    [[page]]
    path = "a.html"
    uses = ["radar"]
    """,
    "pages/a.html" => "a"
  }

  setup %{tmp_dir: tmp_dir} do
    ctx =
      setup_screen(tmp_dir, @files, """
      [upstream.weather]
      base_url = "https://api.example.com"
      """)

    {:ok, _sha} = Revisions.refresh(ctx.config)
    Cache.clear()
    Stats.clear()
    Deepsplay.State.clear()
    ctx
  end

  test "lists namespaces of shared state with their configurations", %{conn: conn} = ctx do
    {:ok, host_config} = Deepsplay.HostConfig.Store.get()
    namespace = Deepsplay.State.namespace(host_config, ctx.config)
    {:ok, _} = Deepsplay.State.put(namespace, "shared/msg", ~s("hi"))
    {:ok, _} = Deepsplay.State.put("name:old", "k", "1")

    {:ok, view, _html} = live(conn, ~p"/status")

    assert has_element?(view, "#status-state tr", namespace)
    assert has_element?(view, "#status-state tr", "lobby")
    assert has_element?(view, "#status-state .state-keys", "1 key,")
    assert has_element?(view, "#status-state tr", "no configuration")
  end

  test "lists upstreams with origin, cache and counters", %{conn: conn} do
    Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 200, "image"))
    get(build_conn(), "/c/lobby/api/radar/tile")
    get(build_conn(), "/c/lobby/api/radar/tile")

    Cache.expire_all()
    Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 503, "busy"))
    capture_log(fn -> get(build_conn(), "/c/lobby/api/radar/tile") end)

    {:ok, view, _html} = live(conn, ~p"/status")

    assert has_element?(view, "#upstream-host-configuration-weather", "host configuration")
    assert has_element?(view, "#upstream-host-configuration-weather", "not cached")

    radar = "#upstream-manifest-radar"
    assert has_element?(view, radar, "https://radar.example.com/wms")
    assert has_element?(view, radar, "lobby")
    assert has_element?(view, "#{radar} .upstream-cache", "1 entry,")
    assert has_element?(view, "#{radar} .upstream-cache", "of 1.0 MB")
    assert has_element?(view, "#{radar} .upstream-answers", "1 hits, 1 misses, 1 stale")
    assert has_element?(view, "#{radar} .upstream-error", "answered 503")
    assert has_element?(view, "#status-upstreams", "cache")
  end
end
