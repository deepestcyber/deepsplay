defmodule Deepsplay.BackendPublishTest do
  # Publishing revisions with backends (ADR 26), with real uv and Python. Not
  # async: uses the global host configuration and backend registry.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint DeepsplayWeb.Endpoint

  alias Deepsplay.Backend
  alias Deepsplay.Backends
  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RevisionStore
  alias Deepsplay.Revisions

  @moduletag :uv
  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @fixture "test/support/fixtures/backend"

  @manifest """
  [backend]
  dir     = "backend"
  command = ["python", "app.py", "{port}"]
  health  = "/health"

  [[page]]
  path = "a.html"
  """

  defp files(manifest) do
    backend =
      for file <- ~w(app.py pyproject.toml uv.lock),
          into: %{},
          do: {"backend/#{file}", File.read!(Path.join(@fixture, file))}

    Map.merge(backend, %{"screen.toml" => manifest, "pages/a.html" => "a"})
  end

  setup %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "src")
    url = GitFixture.init(src)
    sha = GitFixture.commit(src, files(@manifest))

    {:ok, host_config} =
      HostConfig.parse("""
      [server]
      cache_dir      = "#{tmp_dir}/cache"
      state_dir      = "#{tmp_dir}/state"
      default_config = "lobby"

      [[config]]
      name    = "lobby"
      repo    = "#{url}"
      ref     = "main"
      backend = true

      [[config]]
      name = "plain"
      repo = "#{url}"
      ref  = "main"
      """)

    previous = Store.get()
    Store.put({:ok, host_config})

    on_exit(fn ->
      Backends.stop("lobby")
      Store.put(previous)
    end)

    %{
      src: src,
      url: url,
      sha: sha,
      lobby: host_config.configs["lobby"],
      plain: host_config.configs["plain"]
    }
  end

  test "a revision is published once its backend is ready", ctx do
    assert {:ok, sha} = Revisions.refresh(ctx.lobby)
    assert sha == ctx.sha
    assert RevisionStore.last_good(ctx.url, "config:lobby") == {:ok, sha}

    assert %{sha: ^sha, pid: pid} = Backends.current("lobby")
    assert Backend.info(pid).state == :ready

    # The same revision again keeps the running backend.
    assert {:ok, ^sha} = Revisions.refresh(ctx.lobby)
    assert %{pid: ^pid} = Backends.current("lobby")
  end

  test "a failing backend keeps the last good revision and its backend", ctx do
    {:ok, good} = Revisions.refresh(ctx.lobby)
    %{pid: pid} = Backends.current("lobby")

    broken =
      String.replace(
        @manifest,
        ~S|["python", "app.py", "{port}"]|,
        ~S|["python", "-c", "raise SystemExit(4)"]|
      )

    bad = GitFixture.commit(ctx.src, %{"screen.toml" => broken})

    capture_log(fn ->
      assert {:error, {:rejected, ^bad, "backend: " <> message}} = Revisions.refresh(ctx.lobby)
      assert message =~ "exited with status 4"
    end)

    assert RevisionStore.last_good(ctx.url, "config:lobby") == {:ok, good}
    assert %{sha: ^good, pid: ^pid} = Backends.current("lobby")
    assert Backend.info(pid).state == :ready
    assert Deepsplay.Status.get("lobby").error =~ "backend:"
  end

  test "a new revision replaces the backend; one without backend stops it", ctx do
    {:ok, _first} = Revisions.refresh(ctx.lobby)
    %{pid: old} = Backends.current("lobby")
    ref = Process.monitor(old)

    second = GitFixture.commit(ctx.src, %{"pages/a.html" => "a2"})
    assert {:ok, ^second} = Revisions.refresh(ctx.lobby)
    assert %{sha: ^second, pid: new} = Backends.current("lobby")
    refute new == old
    assert_receive {:DOWN, ^ref, :process, ^old, _reason}

    third = GitFixture.commit(ctx.src, %{"screen.toml" => ~s([[page]]\npath = "a.html"\n)})
    assert {:ok, ^third} = Revisions.refresh(ctx.lobby)
    assert Backends.current("lobby") == nil
  end

  test "without the repository, the last good revision's backend still starts", ctx do
    {:ok, good} = Revisions.refresh(ctx.lobby)
    Backends.stop("lobby")
    File.rename!(ctx.src, ctx.src <> "-gone")

    capture_log(fn -> assert {:error, {:fetch, _}} = Revisions.refresh(ctx.lobby) end)
    assert %{sha: ^good} = Backends.current("lobby")
  end

  test "pages reach the backend through the proxy", ctx do
    {:ok, _sha} = Revisions.refresh(ctx.lobby)

    assert build_conn() |> get("/c/lobby/backend/health") |> response(200) == "ok"

    env = build_conn() |> get("/c/lobby/backend/env") |> response(200) |> Jason.decode!()
    assert env["DEEPSPLAY_CONFIG"] == "lobby"

    echo =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("cookie", "session=1")
      |> get("/c/lobby/backend/echo?x=1&y=a%20b")
      |> response(200)
      |> Jason.decode!()

    assert echo == %{"path" => "/echo?x=1&y=a+b", "accept" => "application/json"}

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/c/lobby/backend/items", ~s({"a":1}))

    assert response(conn, 201) == ~s(got {"a":1})

    assert build_conn() |> get("/c/lobby/backend/missing") |> response(404) == ""
    assert build_conn() |> get("/c/lobby/backend/%2e%2e/x") |> response(404) == "invalid path"

    assert build_conn() |> get("/c/plain/backend/health") |> response(404) =~ "no backend"
    assert build_conn() |> get("/c/nowhere/backend/health") |> response(404) =~ "unknown"

    Backends.stop("lobby")
    assert build_conn() |> get("/c/lobby/backend/health") |> response(404) =~ "no backend"
  end

  test "configurations without backend = true do not run it", ctx do
    assert {:ok, _sha} = Revisions.refresh(ctx.plain)
    assert Backends.current("plain") == nil
  end
end
