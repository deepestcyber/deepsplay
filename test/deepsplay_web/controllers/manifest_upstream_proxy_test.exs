defmodule DeepsplayWeb.ManifestUpstreamProxyTest do
  # Not async: uses the global host configuration and proxy cache.
  use DeepsplayWeb.ConnCase, async: false

  import Deepsplay.ScreenFixture
  import ExUnit.CaptureLog

  alias Deepsplay.Revisions
  alias Deepsplay.UpstreamProxy.Cache

  @moduletag :tmp_dir
  @stub Deepsplay.UpstreamProxy

  setup %{tmp_dir: tmp_dir} do
    files = %{
      "screen.toml" => """
      [upstream.radar]
      url       = "https://radar.example.com/wms"
      cache_ttl = "5m"

      [upstream.inside]
      url       = "https://internal.example.com"
      cache_ttl = "5m"

      [[page]]
      path = "a.html"
      uses = ["radar", "inside"]
      """,
      "pages/a.html" => "a"
    }

    %{config: config} = setup_screen(tmp_dir, files)
    {:ok, _sha} = Revisions.refresh(config)
    Cache.clear()
    :ok
  end

  test "forwards GET requests to a checked address, cached", %{conn: conn} do
    test = self()

    Req.Test.stub(@stub, fn upstream ->
      send(test, {:upstream, upstream.host, upstream.request_path, upstream.query_string})
      Plug.Conn.send_resp(upstream, 200, "image")
    end)

    conn = get(conn, "/c/lobby/api/radar/tile?bbox=1,2,3,4")
    assert response(conn, 200) == "image"
    assert get_resp_header(conn, "x-deepsplay-cache") == ["miss"]
    # The request goes to the resolved public address (IPv4 preferred).
    assert_received {:upstream, "93.184.216.34", "/wms/tile", "bbox=1%2C2%2C3%2C4"}

    hit = get(build_conn(), "/c/lobby/api/radar/tile?bbox=1,2,3,4")
    assert get_resp_header(hit, "x-deepsplay-cache") == ["hit"]
    refute_received {:upstream, _host, _path, _query}
  end

  test "allows GET only", %{conn: conn} do
    assert conn |> post("/c/lobby/api/radar/tile") |> response(405)
  end

  test "refuses hosts with non-public addresses", %{conn: conn} do
    Req.Test.stub(@stub, fn _upstream -> flunk("must not be called") end)

    log =
      capture_log(fn ->
        assert conn |> get("/c/lobby/api/inside/x") |> response(502) =~ "non-public address"
      end)

    assert log =~ "proxy inside"
  end
end
