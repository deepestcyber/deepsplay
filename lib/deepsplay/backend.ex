defmodule Deepsplay.Backend do
  @moduledoc """
  Runs one backend (ADR 26): installs its environment with `uv`, starts the
  process with a clean environment and an optional memory limit, waits until
  it is ready, restarts it with backoff when it crashes, and keeps the last
  lines of its output.

  States: `:syncing` (`uv sync --frozen`), `:starting` (waiting for
  readiness), `:ready`, `:restarting` (after a crash, waiting for the
  backoff), `:failed` (sync or start failed, or too many crashes; the error
  says why). `await_ready/2` waits for `:ready` or `:failed`.

  The environment lives outside the revision (`env_dir`, shared by revisions
  with the same `uv.lock`); Python is installed by `uv` below `uv_dir`.

  The process gets only: `PORT`, `HOME` (its data directory), `PATH` (the
  environment's `bin` first), `VIRTUAL_ENV`, `PYTHONDONTWRITEBYTECODE`,
  `UV_CACHE_DIR`, `DEEPSPLAY_CONFIG`, `DEEPSPLAY_URL`, `DEEPSPLAY_DATA_DIR`,
  `DEEPSPLAY_TOKEN` and the secrets passed in `:secrets`.

  `DEEPSPLAY_TOKEN` triggers the configuration's interrupts (ADR 32). It is
  new at every start of the process and valid while the process runs
  (`Deepsplay.InterruptTokens`).
  """

  use GenServer

  require Logger

  alias Deepsplay.InterruptTokens
  alias Deepsplay.Screen.Backend, as: Spec

  @sync_timeout 10 * 60_000
  @start_timeout 60_000
  @ready_poll 250
  @stop_grace 5_000
  @output_lines 100
  @max_crashes 5
  @crash_window 5 * 60_000
  @system_path "/usr/local/bin:/usr/bin:/bin"

  @type state_name :: :syncing | :starting | :ready | :restarting | :failed

  @type info :: %{
          state: state_name(),
          port: pos_integer() | nil,
          started_at: DateTime.t() | nil,
          restarts: non_neg_integer(),
          error: String.t() | nil,
          last_crash: String.t() | nil,
          output: [String.t()]
        }

  @doc """
  Starts a backend. Options:

    * `:name` - the configuration's name (required)
    * `:root` - the revision's root directory, with the backend's `dir`
      (required)
    * `:spec` - the `Deepsplay.Screen.Backend` (required)
    * `:env_dir` - where the Python environment lives (required)
    * `:uv_dir` - cache and Python installations of `uv` (required)
    * `:data_dir` - the backend's persistent directory (required)
    * `:url` - how the backend reaches deepsplay (`DEEPSPLAY_URL`)
    * `:secrets` - `%{name => value}` passed as environment variables
    * `:memory` - memory limit in bytes, or `nil`
    * `:uv` - the `uv` executable, default from `PATH`
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Waits until the backend is ready (`:ok`) or has failed
  (`{:error, message}`).
  """
  @spec await_ready(pid(), timeout()) :: :ok | {:error, String.t()}
  def await_ready(backend, timeout \\ @sync_timeout + @start_timeout) do
    GenServer.call(backend, :await_ready, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, "not ready in time"}
  end

  @doc """
  State, port, start time, restarts, the current error (`nil` while ready),
  the last crash, and recent output.
  """
  @spec info(pid()) :: info()
  def info(backend), do: GenServer.call(backend, :info)

  @doc "Stops the process (TERM, then KILL after #{div(@stop_grace, 1000)} s) and the backend."
  @spec stop(pid()) :: :ok
  def stop(backend), do: GenServer.stop(backend, :normal, @stop_grace + 5_000)

  @doc """
  The directory for a backend's environment: one per `uv.lock`, so
  revisions with the same dependencies share it.
  """
  @spec env_dir(Path.t(), Path.t(), Spec.t()) :: Path.t()
  def env_dir(base, root, %Spec{dir: dir}) do
    lock = File.read!(Path.join([root, dir, "uv.lock"]))
    pyproject = File.read!(Path.join([root, dir, "pyproject.toml"]))
    hash = :crypto.hash(:sha256, [lock, 0, pyproject]) |> Base.encode16(case: :lower)
    Path.join(base, binary_part(hash, 0, 16))
  end

  # Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    spec = Keyword.fetch!(opts, :spec)

    state = %{
      name: Keyword.fetch!(opts, :name),
      dir: Path.join(Keyword.fetch!(opts, :root), spec.dir),
      spec: spec,
      env_dir: Keyword.fetch!(opts, :env_dir),
      uv_dir: Keyword.fetch!(opts, :uv_dir),
      data_dir: Keyword.fetch!(opts, :data_dir),
      url: Keyword.get(opts, :url),
      secrets: Keyword.get(opts, :secrets, %{}),
      memory: Keyword.get(opts, :memory),
      uv: Keyword.get_lazy(opts, :uv, fn -> System.find_executable("uv") end),
      status: :syncing,
      port: nil,
      os_port: nil,
      os_pid: nil,
      token: nil,
      started_at: nil,
      restarts: 0,
      crashes: [],
      error: nil,
      last_crash: nil,
      output: :queue.new(),
      waiters: [],
      timer: nil
    }

    {:ok, state, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    case sync(state) do
      :ok -> {:noreply, launch(state)}
      {:error, message} -> {:noreply, fail(state, message)}
    end
  end

  @impl true
  def handle_call(:await_ready, from, %{status: status} = state)
      when status in [:syncing, :starting, :restarting] do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await_ready, _from, %{status: :ready} = state), do: {:reply, :ok, state}
  def handle_call(:await_ready, _from, state), do: {:reply, {:error, state.error}, state}

  def handle_call(:info, _from, state) do
    info = %{
      state: state.status,
      port: state.port,
      started_at: state.started_at,
      restarts: state.restarts,
      error: state.error,
      last_crash: state.last_crash,
      output: :queue.to_list(state.output)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info({os_port, {:data, {_eol, line}}}, %{os_port: os_port} = state),
    do: {:noreply, add_output(state, line)}

  def handle_info({os_port, {:exit_status, code}}, %{os_port: os_port} = state) do
    state = stopped(state)
    message = "process exited with status #{code}"
    Logger.warning(~s(backend of "#{state.name}": #{message}))
    {:noreply, crashed(state, message)}
  end

  def handle_info(:check_ready, %{status: :starting} = state), do: {:noreply, check_ready(state)}
  def handle_info(:restart, %{status: :restarting} = state), do: {:noreply, launch(state)}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  def handle_info(_stale, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: kill(state)

  # uv sync, with a time limit; the environment lives outside the revision.
  defp sync(%{uv: nil}), do: {:error, "uv is not installed"}

  defp sync(state) do
    File.mkdir_p!(state.uv_dir)

    env = [
      {"UV_PROJECT_ENVIRONMENT", state.env_dir},
      {"UV_CACHE_DIR", Path.join(state.uv_dir, "cache")},
      {"UV_PYTHON_INSTALL_DIR", Path.join(state.uv_dir, "python")},
      {"UV_NO_PROGRESS", "1"}
    ]

    args = ["sync", "--frozen", "--project", state.dir]

    case run(state.uv, args, env, @sync_timeout) do
      {:ok, _output} -> :ok
      {:error, output} -> {:error, "uv sync failed: " <> last_lines(output)}
    end
  end

  defp run(executable, args, env, timeout) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    collect(port, "", System.monotonic_time(:millisecond) + timeout)
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> collect(port, output <> data, deadline)
      {^port, {:exit_status, 0}} -> {:ok, output}
      {^port, {:exit_status, _code}} -> {:error, output}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)])
          nil -> :ok
        end

        {:error, output <> "\n(timed out)"}
    end
  end

  defp last_lines(output) do
    output |> String.split("\n", trim: true) |> Enum.take(-5) |> Enum.join(" | ")
  end

  # Starts the process: `env -i` for a clean environment, `sh` for the
  # memory limit, then `exec`, so the process id is the backend's own.
  defp launch(state) do
    port = free_port()
    token = InterruptTokens.generate()
    state = %{state | token: token}
    File.mkdir_p!(state.data_dir)
    command = Enum.map(state.spec.command, &String.replace(&1, "{port}", Integer.to_string(port)))
    limit = if state.memory, do: "ulimit -v #{div(state.memory, 1024)}; ", else: ""

    args =
      Enum.map(environment(state, port), fn {k, v} -> "#{k}=#{v}" end) ++
        ["/bin/sh", "-c", limit <> ~s(exec "$@"), "sh" | command]

    os_port =
      Port.open({:spawn_executable, "/usr/bin/env"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 2048},
        {:cd, state.dir},
        args: ["-i" | args]
      ])

    {:os_pid, os_pid} = Port.info(os_port, :os_pid)
    InterruptTokens.register(state.name, token)
    Process.send_after(self(), :check_ready, @ready_poll)

    %{
      state
      | status: :starting,
        port: port,
        os_port: os_port,
        os_pid: os_pid,
        started_at: DateTime.utc_now(),
        timer: System.monotonic_time(:millisecond) + @start_timeout
    }
  end

  defp environment(state, port) do
    [
      {"PORT", Integer.to_string(port)},
      {"HOME", state.data_dir},
      {"PATH", Path.join(state.env_dir, "bin") <> ":" <> @system_path},
      {"VIRTUAL_ENV", state.env_dir},
      {"PYTHONDONTWRITEBYTECODE", "1"},
      {"PYTHONUNBUFFERED", "1"},
      {"UV_CACHE_DIR", Path.join(state.uv_dir, "cache")},
      {"DEEPSPLAY_CONFIG", state.name},
      {"DEEPSPLAY_DATA_DIR", state.data_dir},
      {"DEEPSPLAY_TOKEN", state.token}
    ] ++
      if(state.url, do: [{"DEEPSPLAY_URL", state.url}], else: []) ++
      Enum.sort(state.secrets)
  end

  # The OS process is gone: so is its token.
  defp stopped(state) do
    InterruptTokens.unregister(state.name)
    %{state | os_port: nil, os_pid: nil, token: nil}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp check_ready(state) do
    cond do
      ready?(state) ->
        Logger.info(~s(backend of "#{state.name}" is ready on port #{state.port}))
        reply_waiters(%{state | status: :ready, error: nil}, :ok)

      System.monotonic_time(:millisecond) > state.timer ->
        kill(state)

        fail(
          stopped(state),
          "not ready within #{div(@start_timeout, 1000)} s"
        )

      true ->
        Process.send_after(self(), :check_ready, @ready_poll)
        state
    end
  end

  defp ready?(%{spec: %Spec{health: nil}} = state) do
    case :gen_tcp.connect({127, 0, 0, 1}, state.port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp ready?(%{spec: %Spec{health: path}} = state) do
    case Req.get("http://127.0.0.1:#{state.port}#{path}",
           retry: false,
           receive_timeout: 1_000,
           connect_options: [timeout: 500]
         ) do
      {:ok, %Req.Response{status: status}} -> status in 200..299
      {:error, _exception} -> false
    end
  end

  # A crash while starting the first time is a failed start; later ones
  # restart with backoff, unless they come too often.
  defp crashed(%{status: :starting, restarts: 0} = state, message),
    do: fail(state, "#{message} before it was ready")

  defp crashed(state, message) do
    now = System.monotonic_time(:millisecond)
    crashes = [now | Enum.filter(state.crashes, &(&1 > now - @crash_window))]

    if length(crashes) >= @max_crashes do
      fail(%{state | crashes: crashes}, "#{message}; stopped after #{@max_crashes} crashes")
    else
      backoff = min(1_000 * 2 ** (length(crashes) - 1), 60_000)
      Process.send_after(self(), :restart, backoff)

      %{
        state
        | status: :restarting,
          crashes: crashes,
          restarts: state.restarts + 1,
          error: message,
          last_crash: message
      }
    end
  end

  defp fail(state, message) do
    Logger.warning(~s(backend of "#{state.name}" failed: #{message}))
    reply_waiters(%{state | status: :failed, error: message}, {:error, message})
  end

  defp reply_waiters(state, reply) do
    Enum.each(state.waiters, &GenServer.reply(&1, reply))
    %{state | waiters: []}
  end

  defp add_output(state, line) do
    output = :queue.in(line, state.output)
    output = if :queue.len(output) > @output_lines, do: :queue.drop(output), else: output
    %{state | output: output}
  end

  defp kill(%{os_pid: nil}), do: :ok

  defp kill(%{os_pid: pid, os_port: port}) do
    pid = Integer.to_string(pid)
    System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _code}} -> :ok
    after
      @stop_grace -> System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    end

    :ok
  end
end
