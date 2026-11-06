defmodule DeepsplayWeb.RevisionControllerTest do
  # Not async: replaces the globally stored host configuration.
  use DeepsplayWeb.ConnCase, async: false

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RevisionStore

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "src")
    url = GitFixture.init(src)
    cache = Path.join(tmp_dir, "cache")

    sha =
      GitFixture.commit(src, %{
        "README.md" => "outside the subdir",
        "screens/lobby/screen.toml" => ~s([[page]]\npath = "index.html"\nduration = "1s"\n),
        "screens/lobby/notes.md" => "outside pages/",
        "screens/lobby/pages/index.html" => "<h1>Lobby</h1>",
        "screens/lobby/pages/css/app.css" => "h1 {}",
        "screens/lobby/pages/data.json" => "{}",
        "screens/lobby/pages/.env" => "SECRET=1",
        "screens/lobby/pages/.well-hidden/x.html" => "x",
        "screens/other/pages/index.html" => "other"
      })

    {:ok, ^sha} = RevisionStore.publish(url, "main", cache_dir: cache)

    {:ok, host_config} =
      HostConfig.parse("""
      [server]
      cache_dir      = "#{cache}"
      default_config = "lobby"

      [[config]]
      name   = "lobby"
      repo   = "#{url}"
      ref    = "main"
      subdir = "screens/lobby"

      [[config]]
      name = "other"
      repo = "file:///nonexistent/other"
      ref  = "main"
      """)

    previous = Store.get()
    Store.put({:ok, host_config})
    on_exit(fn -> Store.put(previous) end)

    %{sha: sha}
  end

  test "serves a file with immutable caching and its content type", %{conn: conn, sha: sha} do
    conn = get(conn, "/c/lobby/r/#{sha}/index.html")

    assert response(conn, 200) == "<h1>Lobby</h1>"
    assert get_resp_header(conn, "content-type") == ["text/html"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "serves nested files and derives types from the extension", %{conn: conn, sha: sha} do
    assert conn |> get("/c/lobby/r/#{sha}/css/app.css") |> response_content_type(:css) =~
             "text/css"

    conn = get(build_conn(), "/c/lobby/r/#{sha}/data.json")
    assert response(conn, 200) == "{}"
    assert get_resp_header(conn, "content-type") == ["application/json"]
  end

  test "serves nothing outside pages/ and no hidden files", %{conn: conn, sha: sha} do
    for path <- [
          "README.md",
          "screen.toml",
          "notes.md",
          "pages/index.html",
          ".env",
          ".well-hidden/x.html",
          "../other/pages/index.html"
        ] do
      assert conn |> get("/c/lobby/r/#{sha}/#{path}") |> response(404), path
    end
  end

  test "rejects traversal", %{conn: conn, sha: sha} do
    for path <- ["../README.md", "..%2FREADME.md", "%2e%2e/README.md", "css/../../README.md"] do
      conn = get(conn, "/c/lobby/r/#{sha}/#{path}")
      assert response(conn, 404), path
    end
  end

  test "answers 404 without caching for unknown things", %{conn: conn, sha: sha} do
    unknown_sha = String.duplicate("a", 40)

    for path <- [
          "/c/lobby/r/#{sha}/missing.html",
          "/c/lobby/r/#{sha}/css",
          "/c/lobby/r/#{unknown_sha}/index.html",
          "/c/lobby/r/main/index.html",
          "/c/nowhere/r/#{sha}/index.html",
          "/c/other/r/#{sha}/index.html"
        ] do
      conn = get(conn, path)
      assert response(conn, 404) == "Not found", path
      assert get_resp_header(conn, "cache-control") == ["no-store"], path
    end
  end

  test "answers 404 when the host configuration is unusable", %{conn: conn, sha: sha} do
    Store.put({:error, ["broken"]})
    assert conn |> get("/c/lobby/r/#{sha}/index.html") |> response(404)
  end
end
