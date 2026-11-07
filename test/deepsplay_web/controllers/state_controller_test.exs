defmodule DeepsplayWeb.StateControllerTest do
  # Not async: uses the global host configuration and state store.
  use DeepsplayWeb.ConnCase, async: false

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.State

  setup do
    {:ok, host_config} =
      HostConfig.parse("""
      [server]
      cache_dir      = "/tmp/unused"
      default_config = "lobby"

      [[config]]
      name = "lobby"
      repo = "https://example.com/screens.git"
      ref  = "main"

      [[config]]
      name     = "kitchen"
      repo     = "https://example.com/screens.git"
      ref      = "main"
      manifest = "kitchen.toml"

      [[config]]
      name  = "quiet"
      repo  = "https://example.com/screens.git"
      ref   = "main"
      state = false
      """)

    previous = Store.get()
    Store.put({:ok, host_config})
    State.clear()
    on_exit(fn -> Store.put(previous) end)
    :ok
  end

  defp put_json(conn, path, body, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> put_req_header("content-type", "application/json")
    |> put(path, body)
  end

  test "stores and reads values with versions", %{conn: conn} do
    assert conn |> get("/c/lobby/state/life/gen") |> json_response(404)

    conn = put_json(build_conn(), "/c/lobby/state/life/gen", ~s({"n": 1}))
    assert json_response(conn, 200) == %{"version" => 1}
    assert get_resp_header(conn, "etag") == [~s("1")]

    conn = get(build_conn(), "/c/lobby/state/life/gen")
    assert json_response(conn, 200) == %{"n" => 1}
    assert get_resp_header(conn, "etag") == [~s("1")]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    # Any JSON value, also without a JSON content type.
    assert put_json(build_conn(), "/c/lobby/state/shared/msg", ~s("hello")) |> json_response(200)
    assert build_conn() |> get("/c/lobby/state/shared/msg") |> json_response(200) == "hello"

    conn =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> put("/c/lobby/state/n", "42")

    assert json_response(conn, 200)
    assert build_conn() |> get("/c/lobby/state/n") |> json_response(200) == 42
  end

  test "configurations on one repository and ref share state", %{conn: conn} do
    put_json(conn, "/c/lobby/state/shared/msg", ~s("hi"))
    assert build_conn() |> get("/c/kitchen/state/shared/msg") |> json_response(200) == "hi"
  end

  test "lists keys by prefix", %{conn: conn} do
    put_json(conn, "/c/lobby/state/life/a", "1")
    put_json(build_conn(), "/c/lobby/state/life/b", "2")
    put_json(build_conn(), "/c/lobby/state/clock", "3")

    assert build_conn() |> get("/c/lobby/state/?prefix=life/") |> json_response(200) == %{
             "keys" => [
               %{"key" => "life/a", "version" => 1},
               %{"key" => "life/b", "version" => 2}
             ]
           }

    assert %{"keys" => [_, _, _]} = build_conn() |> get("/c/lobby/state") |> json_response(200)
  end

  test "deletes, also conditionally", %{conn: conn} do
    put_json(conn, "/c/lobby/state/k", "1")

    conn = build_conn() |> put_req_header("if-match", ~s("9")) |> delete("/c/lobby/state/k")
    assert json_response(conn, 412)

    assert build_conn() |> delete("/c/lobby/state/k") |> response(204)
    assert build_conn() |> get("/c/lobby/state/k") |> json_response(404)
  end

  test "conditional writes", %{conn: conn} do
    create = [{"if-none-match", "*"}]
    assert put_json(conn, "/c/lobby/state/k", "1", create) |> json_response(200)
    assert put_json(build_conn(), "/c/lobby/state/k", "2", create) |> json_response(412)

    assert put_json(build_conn(), "/c/lobby/state/k", "2", [{"if-match", ~s("1")}])
           |> json_response(200)

    assert put_json(build_conn(), "/c/lobby/state/k", "3", [{"if-match", ~s("1")}])
           |> json_response(412)

    assert put_json(build_conn(), "/c/lobby/state/k", "3", [{"if-match", "nope"}])
           |> json_response(400)
  end

  test "increments numbers", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/c/lobby/state/visits", ~s({"increment": 2}))

    assert json_response(conn, 200) == %{"value" => 2, "version" => 1}

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/c/lobby/state/visits", ~s({"increment": 1}))

    assert json_response(conn, 200) == %{"value" => 3, "version" => 2}

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/c/lobby/state/visits", ~s({"by": 1}))

    assert json_response(conn, 400)

    put_json(build_conn(), "/c/lobby/state/text", ~s("x"))

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/c/lobby/state/text", ~s({"increment": 1}))

    assert json_response(conn, 409)
  end

  test "refuses invalid keys and values and enforces limits", %{conn: conn} do
    assert put_json(conn, "/c/lobby/state/.hidden", "1") |> json_response(400)

    conn =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> put("/c/lobby/state/k", "{nope")

    assert json_response(conn, 400) == %{"error" => "body must be JSON"}

    big = Jason.encode!(String.duplicate("x", 70 * 1024))
    assert put_json(build_conn(), "/c/lobby/state/big", big) |> json_response(413)

    conn =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> put("/c/lobby/state/big", big)

    assert json_response(conn, 413)
  end

  test "configurations without state and unknown ones", %{conn: conn} do
    assert conn |> get("/c/quiet/state/k") |> json_response(404) == %{
             "error" => "no shared state for this configuration"
           }

    assert build_conn() |> get("/c/nope/state/k") |> json_response(404) == %{
             "error" => "unknown configuration"
           }
  end
end
