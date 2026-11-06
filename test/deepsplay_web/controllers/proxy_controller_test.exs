defmodule DeepsplayWeb.ProxyControllerTest do
  # Not async: uses the global host configuration, secrets and proxy cache.
  use DeepsplayWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Secrets
  alias Deepsplay.Status
  alias Deepsplay.UpstreamProxy.Cache

  @stub Deepsplay.UpstreamProxy
  @secret "s3cr3t-value"

  setup do
    {:ok, host_config} =
      HostConfig.parse(
        """
        [server]
        cache_dir      = "/tmp/unused"
        default_config = "lobby"

        [upstream.weather]
        base_url    = "https://api.example.com/v1/"
        header      = "Authorization"
        value       = "Bearer {secret:weather_api}"
        query       = "appid"
        query_value = "{secret:weather_api}"

        [upstream.cached]
        base_url  = "https://cache.example.com"
        cache_ttl = "60s"

        [upstream.writer]
        base_url = "https://write.example.com"
        methods  = ["GET", "POST"]

        [[config]]
        name      = "lobby"
        path      = "/srv/lobby"
        upstreams = ["weather", "cached", "writer"]

        [[config]]
        name = "kitchen"
        path = "/srv/kitchen"
        """,
        secrets: ["weather_api"]
      )

    previous = Store.get()
    Store.put({:ok, host_config})
    Secrets.put(%{"weather_api" => @secret})
    Cache.clear()
    Status.clear()

    on_exit(fn ->
      Store.put(previous)
      Secrets.put(%{})
    end)

    :ok
  end

  test "forwards with the secret added and client credentials removed", %{conn: conn} do
    test = self()

    Req.Test.stub(@stub, fn upstream ->
      send(test, {:upstream, upstream})

      upstream
      |> Plug.Conn.put_resp_header("set-cookie", "tracking=1")
      |> Plug.Conn.put_resp_header("x-internal", "secret-stuff")
      |> Req.Test.json(%{temperature: 21})
    end)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer client")
      |> put_req_header("cookie", "session=abc")
      |> get("/c/lobby/api/weather/current/berlin?units=metric&appid=forged")

    assert json_response(conn, 200) == %{"temperature" => 21}
    assert get_resp_header(conn, "set-cookie") == []
    assert get_resp_header(conn, "x-internal") == []

    assert_received {:upstream, upstream}
    assert upstream.host == "api.example.com"
    assert upstream.request_path == "/v1/current/berlin"
    assert URI.decode_query(upstream.query_string) == %{"units" => "metric", "appid" => @secret}
    assert Plug.Conn.get_req_header(upstream, "authorization") == ["Bearer #{@secret}"]
    assert Plug.Conn.get_req_header(upstream, "cookie") == []
    assert Plug.Conn.get_req_header(upstream, "accept") == ["application/json"]
  end

  test "passes the upstream status on", %{conn: conn} do
    Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 404, "no such city"))
    assert conn |> get("/c/lobby/api/weather/x") |> response(404) == "no such city"
  end

  test "refuses upstreams, methods and paths that are not allowed", %{conn: conn} do
    Req.Test.stub(@stub, fn _conn -> flunk("must not reach the upstream") end)

    assert conn |> get("/c/kitchen/api/weather/x") |> response(403) =~ "not allowed"
    assert build_conn() |> get("/c/lobby/api/nope/x") |> response(403)
    assert build_conn() |> get("/c/nowhere/api/weather/x") |> response(404)
    assert build_conn() |> post("/c/lobby/api/weather/x") |> response(405)
    assert build_conn() |> get("/c/lobby/api/weather/%2e%2e/admin") |> response(404)
    assert build_conn() |> get("/c/lobby/api/weather/a%2Fb") |> response(404)
  end

  test "forwards bodies of allowed methods", %{conn: conn} do
    test = self()

    Req.Test.stub(@stub, fn upstream ->
      {:ok, body, upstream} = Plug.Conn.read_body(upstream)
      send(test, {:body, upstream.method, body})
      Plug.Conn.send_resp(upstream, 201, "created")
    end)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/c/lobby/api/writer/items", ~s({"a":1}))

    assert response(conn, 201) == "created"
    assert_received {:body, "POST", ~s({"a":1})}
  end

  test "caches successful GET answers for cache_ttl", %{conn: conn} do
    test = self()

    Req.Test.stub(@stub, fn upstream ->
      send(test, :called)
      Plug.Conn.send_resp(upstream, 200, "fresh")
    end)

    assert conn |> get("/c/lobby/api/cached/data") |> response(200) == "fresh"
    assert build_conn() |> get("/c/lobby/api/cached/data") |> response(200) == "fresh"
    assert_received :called
    refute_received :called

    assert build_conn() |> get("/c/lobby/api/cached/other") |> response(200)
    assert_received :called
  end

  test "answers 504 on timeouts and 502 on other failures, logging them", %{conn: conn} do
    Req.Test.stub(@stub, &Req.Test.transport_error(&1, :timeout))
    log = capture_log(fn -> assert conn |> get("/c/lobby/api/weather/x") |> response(504) end)
    assert log =~ "proxy weather: timed out"

    Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))
    capture_log(fn -> assert build_conn() |> get("/c/lobby/api/weather/x") |> response(502) end)

    _ = :sys.get_state(Status)
    assert [%{config: "lobby", message: "proxy weather: " <> _} | _] = Status.recent_errors()
    refute log =~ @secret
  end

  test "refuses answers larger than the limit", %{conn: conn} do
    Req.Test.stub(@stub, &Plug.Conn.send_resp(&1, 200, :binary.copy("x", 5 * 1024 * 1024 + 1)))

    capture_log(fn ->
      assert conn |> get("/c/lobby/api/weather/big") |> response(502) =~ "larger than 5 MB"
    end)
  end
end
