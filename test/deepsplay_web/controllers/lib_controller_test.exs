defmodule DeepsplayWeb.LibControllerTest do
  use DeepsplayWeb.ConnCase, async: true

  alias DeepsplayWeb.LibController

  test "/lib/v1/deepsplay.js serves the current build, cached with revalidation", %{conn: conn} do
    conn = get(conn, "/lib/v1/deepsplay.js")

    assert response(conn, 200) =~ "window.Deepsplay"
    assert get_resp_header(conn, "content-type") == ["text/javascript; charset=utf-8"]

    assert get_resp_header(conn, "cache-control") == [
             "public, max-age=86400, stale-while-revalidate=604800"
           ]
  end

  test "the exact current version is served immutably", %{conn: conn} do
    conn = get(conn, "/lib/deepsplay@#{LibController.version()}.js")

    assert response(conn, 200) =~ ~s("#{LibController.version()}")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "unknown versions and other files are 404", %{conn: conn} do
    assert conn |> get("/lib/deepsplay@0.0.1.js") |> response(404)
    assert build_conn() |> get("/lib/deepsplay@latest.js") |> response(404)
    assert build_conn() |> get("/lib/archive") |> response(404)
    assert build_conn() |> get("/lib/v2/deepsplay.js") |> response(404)
  end
end
