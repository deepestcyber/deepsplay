defmodule Deepsplay.BackendLocalTest do
  # Backends of local directories (ADR 12, ADR 26), with real uv, Python and
  # file watching. Not async: uses the global host configuration and backend
  # registry.
  use ExUnit.Case, async: false

  alias Deepsplay.Backend
  alias Deepsplay.Backends
  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.LocalWatcher

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

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "screens")
    File.mkdir_p!(Path.join(dir, "backend"))
    File.mkdir_p!(Path.join(dir, "pages"))

    for file <- ~w(app.py pyproject.toml uv.lock),
        do: File.cp!(Path.join(@fixture, file), Path.join([dir, "backend", file]))

    File.write!(Path.join(dir, "screen.toml"), @manifest)
    File.write!(Path.join(dir, "pages/a.html"), "a")

    {:ok, host_config} =
      HostConfig.parse("""
      [server]
      cache_dir      = "#{tmp_dir}/cache"
      state_dir      = "#{tmp_dir}/state"
      default_config = "dev"

      [[config]]
      name    = "dev"
      path    = "#{dir}"
      backend = true
      """)

    previous = Store.get()
    Store.put({:ok, host_config})

    on_exit(fn ->
      Backends.stop("dev")
      Store.put(previous)
    end)

    start_supervised!({LocalWatcher, host_config.configs["dev"]})
    %{dir: dir}
  end

  # Polls for up to 60 seconds (uv sync and the start may take a while).
  defp wait_for(fun, tries \\ 600) do
    case fun.() do
      nil when tries > 0 ->
        receive do
        after
          100 -> wait_for(fun, tries - 1)
        end

      nil ->
        flunk("not reached in time")

      value ->
        value
    end
  end

  defp ready_backend(not_pid \\ nil) do
    wait_for(fn ->
      with %{pid: pid} when pid != not_pid <- Backends.current("dev"),
           %{state: :ready} <- Backend.info(pid) do
        pid
      else
        _other -> nil
      end
    end)
  end

  test "runs the backend from the directory and replaces it when its files change", ctx do
    first = ready_backend()

    # A page change leaves the backend running.
    File.write!(Path.join(ctx.dir, "pages/a.html"), "a2")

    receive do
    after
      1_000 -> :ok
    end

    assert %{pid: ^first} = Backends.current("dev")

    # A change in the backend's dir replaces it.
    File.write!(
      Path.join([ctx.dir, "backend", "app.py"]),
      File.read!(Path.join(@fixture, "app.py")) <> "\n# changed\n"
    )

    second = ready_backend(first)
    refute second == first

    # Without [backend], it stops.
    File.write!(Path.join(ctx.dir, "screen.toml"), ~s([[page]]\npath = "a.html"\n))
    wait_for(fn -> if Backends.current("dev") == nil, do: :stopped end)
  end
end
