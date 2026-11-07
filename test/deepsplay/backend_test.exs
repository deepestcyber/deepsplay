defmodule Deepsplay.BackendTest do
  # Runs real backends: uv sync and a Python process (stdlib only, so no
  # network is needed once uv has a Python). Excluded without uv.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Deepsplay.Backend
  alias Deepsplay.Screen.Backend, as: Spec

  @moduletag :uv
  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @fixture "test/support/fixtures/backend"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "rev")
    File.mkdir_p!(Path.join(root, "backend"))

    for file <- ~w(app.py pyproject.toml uv.lock),
        do: File.cp!(Path.join(@fixture, file), Path.join([root, "backend", file]))

    # One uv directory for all tests of the run, so Python is found or
    # installed once.
    uv_dir = Path.join(System.tmp_dir!(), "deepsplay-test-uv")
    %{root: root, uv_dir: uv_dir, tmp_dir: tmp_dir}
  end

  defp start(ctx, spec_fields \\ [], opts \\ []) do
    spec =
      struct!(
        %Spec{dir: "backend", command: ["python", "app.py", "{port}"], health: "/health"},
        spec_fields
      )

    opts =
      [
        name: "lobby",
        root: ctx.root,
        spec: spec,
        env_dir: Path.join(ctx.tmp_dir, "env"),
        uv_dir: ctx.uv_dir,
        data_dir: Path.join(ctx.tmp_dir, "data"),
        url: "http://127.0.0.1:4000"
      ] ++ opts

    start_supervised!({Backend, opts})
  end

  # Polls a condition for up to 10 seconds.
  defp wait_until(condition, tries \\ 100) do
    cond do
      condition.() ->
        :ok

      tries == 0 ->
        flunk("condition not met in time")

      true ->
        receive do
        after
          100 -> wait_until(condition, tries - 1)
        end
    end
  end

  defp get(backend, path) do
    %{port: port} = Backend.info(backend)
    Req.get!("http://127.0.0.1:#{port}#{path}", retry: false).body
  end

  test "syncs, starts and becomes ready, with a clean environment", ctx do
    backend = start(ctx, [], secrets: %{"weather_api" => "s3cr3t"})
    assert Backend.await_ready(backend) == :ok

    info = Backend.info(backend)
    assert info.state == :ready
    assert Enum.any?(info.output, &(&1 =~ "starting on"))

    env = backend |> get("/env") |> Jason.decode!()
    assert env["PORT"] == Integer.to_string(info.port)
    assert env["DEEPSPLAY_CONFIG"] == "lobby"
    assert env["DEEPSPLAY_URL"] == "http://127.0.0.1:4000"
    assert env["DEEPSPLAY_DATA_DIR"] == env["HOME"]
    assert env["weather_api"] == "s3cr3t"
    assert String.starts_with?(env["PATH"], Path.join(ctx.tmp_dir, "env/bin"))
    # Nothing of deepsplay's own environment.
    refute Map.has_key?(env, "MIX_ENV")
    refute Enum.any?(Map.keys(env), &String.starts_with?(&1, "DEEPSPLAY_SECRET"))
  end

  test "becomes ready on an open port without health path", ctx do
    backend = start(ctx, health: nil)
    assert Backend.await_ready(backend) == :ok
  end

  test "applies the memory limit", ctx do
    backend = start(ctx, [], memory: 1_000_000_000)
    assert Backend.await_ready(backend) == :ok
    assert [soft, _hard] = backend |> get("/limit") |> Jason.decode!()
    assert soft == div(1_000_000_000, 1024) * 1024
  end

  test "restarts after a crash", ctx do
    backend = start(ctx)
    assert Backend.await_ready(backend) == :ok
    %{port: first} = Backend.info(backend)

    capture_log(fn ->
      catch_error(get(backend, "/crash"))
      wait_until(fn -> Backend.info(backend).restarts == 1 end)
      assert Backend.await_ready(backend) == :ok
    end)

    info = Backend.info(backend)
    assert info.state == :ready
    assert info.last_crash =~ "exited with status 3"
    assert info.error == nil
    assert is_integer(first) and is_integer(info.port)
  end

  test "a process that exits before it is ready fails the start", ctx do
    backend = start(ctx, command: ["python", "-c", "raise SystemExit(2)"])

    capture_log(fn ->
      assert {:error, message} = Backend.await_ready(backend)
      assert message =~ "exited with status 2 before it was ready"
    end)

    assert Backend.info(backend).state == :failed
  end

  test "a failed uv sync fails the start", ctx do
    File.write!(Path.join([ctx.root, "backend", "uv.lock"]), "not a lock file")
    backend = start(ctx)

    capture_log(fn ->
      assert {:error, "uv sync failed: " <> _} = Backend.await_ready(backend)
    end)
  end

  test "stopping ends the process", ctx do
    backend = start(ctx)
    assert Backend.await_ready(backend) == :ok
    %{port: port} = Backend.info(backend)

    :ok = stop_supervised(Backend)
    assert {:error, _} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 500)
  end

  test "revisions with the same uv.lock share an environment", ctx do
    spec = %Spec{dir: "backend", command: ["x"]}
    other = Path.join(ctx.tmp_dir, "rev2")
    File.cp_r!(ctx.root, other)

    assert Backend.env_dir("/envs", ctx.root, spec) == Backend.env_dir("/envs", other, spec)

    File.write!(Path.join([other, "backend", "pyproject.toml"]), "[project]\nname = \"x\"\n")
    refute Backend.env_dir("/envs", ctx.root, spec) == Backend.env_dir("/envs", other, spec)
  end
end
