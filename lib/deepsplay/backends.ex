defmodule Deepsplay.Backends do
  @moduledoc """
  The current backend of each configuration (ADR 26).

  `ensure/4` makes sure a configuration's backend runs for a revision: if it
  already does, nothing happens; otherwise a new `Deepsplay.Backend` is
  started and, once ready, replaces the old one, which is then stopped. If
  the new one fails, it is stopped and the old one keeps running. Starting
  and waiting happen in the caller, so a long `uv sync` blocks only the
  configuration being published.
  """

  use GenServer

  alias Deepsplay.Backend
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Screen.Backend, as: Spec
  alias Deepsplay.Secrets

  @supervisor Deepsplay.Backends.Supervisor

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Makes sure the backend `spec` of revision `sha` (rooted at `root`) runs for
  `config`. Returns `:ok` once it is ready, or `{:error, message}`.
  """
  @spec ensure(Config.t(), String.t(), Path.t(), Spec.t()) :: :ok | {:error, String.t()}
  def ensure(%Config{} = config, sha, root, %Spec{} = spec) do
    case current(config.name) do
      %{sha: ^sha, pid: pid} ->
        if Backend.info(pid).state == :failed, do: start(config, sha, root, spec), else: :ok

      _other ->
        start(config, sha, root, spec)
    end
  end

  @doc "Stops the backend of a configuration, if any."
  @spec stop(String.t()) :: :ok
  def stop(name), do: GenServer.call(__MODULE__, {:stop, name})

  @doc "Stops the backends of configurations not in `names`."
  @spec keep_only([String.t()]) :: :ok
  def keep_only(names), do: GenServer.call(__MODULE__, {:keep_only, names})

  @doc """
  All current backends with their revision and `Deepsplay.Backend.info/1`,
  by configuration name.
  """
  @spec all() :: %{String.t() => %{sha: String.t(), info: Backend.info()}}
  def all do
    for {name, %{sha: sha, pid: pid}} <- GenServer.call(__MODULE__, :all),
        info = safe_info(pid),
        info != nil,
        into: %{},
        do: {name, %{sha: sha, info: info}}
  end

  defp safe_info(pid) do
    Backend.info(pid)
  catch
    :exit, _gone -> nil
  end

  @doc "The current backend of a configuration: `%{sha, pid}`, or `nil`."
  @spec current(String.t()) :: %{sha: String.t(), pid: pid()} | nil
  def current(name), do: GenServer.call(__MODULE__, {:current, name})

  defp start(config, sha, root, spec) do
    {:ok, pid} = DynamicSupervisor.start_child(@supervisor, child_spec(config, root, spec))

    case Backend.await_ready(pid) do
      :ok ->
        GenServer.call(__MODULE__, {:swap, config.name, sha, pid})

      {:error, message} ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        {:error, message}
    end
  end

  defp child_spec(config, root, spec) do
    {:ok, host_config} = Store.get()
    cache_dir = host_config.cache_dir

    secrets =
      for name <- spec.secrets,
          name in config.backend_secrets,
          {:ok, value} <- [Secrets.fetch(name)],
          into: %{},
          do: {name, value}

    opts = [
      name: config.name,
      root: root,
      spec: spec,
      env_dir: Backend.env_dir(Path.join(cache_dir, ".backend-envs"), root, spec),
      uv_dir: Path.join(cache_dir, ".uv"),
      data_dir: Path.join([host_config.state_dir, "backends", config.name]),
      url: "http://127.0.0.1:#{endpoint_port()}",
      secrets: secrets,
      memory: config.backend_memory
    ]

    # Stopping waits for the process (TERM, then KILL after 5 s).
    Supervisor.child_spec({Backend, opts}, restart: :temporary, shutdown: 15_000)
  end

  defp endpoint_port do
    case DeepsplayWeb.Endpoint.config(:http) do
      http when is_list(http) -> Keyword.get(http, :port, 4000)
      _other -> 4000
    end
  end

  # Server: name => %{sha, pid}

  @impl true
  def init(nil), do: {:ok, %{}}

  @impl true
  def handle_call({:current, name}, _from, state), do: {:reply, Map.get(state, name), state}
  def handle_call(:all, _from, state), do: {:reply, state, state}

  def handle_call({:swap, name, sha, pid}, _from, state) do
    Process.monitor(pid)
    if old = state[name], do: terminate(old.pid)
    {:reply, :ok, Map.put(state, name, %{sha: sha, pid: pid})}
  end

  def handle_call({:stop, name}, _from, state) do
    if old = state[name], do: terminate(old.pid)
    {:reply, :ok, Map.delete(state, name)}
  end

  def handle_call({:keep_only, names}, _from, state) do
    {gone, kept} = Map.split_with(state, fn {name, _backend} -> name not in names end)
    Enum.each(gone, fn {_name, backend} -> terminate(backend.pid) end)
    {:reply, :ok, kept}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, Map.reject(state, fn {_name, backend} -> backend.pid == pid end)}
  end

  defp terminate(pid), do: DynamicSupervisor.terminate_child(@supervisor, pid)
end
