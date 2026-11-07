defmodule Deepsplay.LocalWatcher do
  @moduledoc """
  Watches the local directory of a configuration with `path` (ADR 12,
  development only).

  Files are served straight from the directory. The watcher keeps a version
  token that takes the place of the commit SHA in page URLs; every relevant
  change gets a new token, which is announced like a new revision, so screens
  load the new URLs and nothing stale stays cached.

  Only the manifest and `pages/` are watched (`pages/` recursively, the
  manifest's directory on its own), so the rest of a big repository costs
  nothing. Bursts of changes, as editors produce on save, are handled as one
  after 200 ms.

  With a backend (ADR 26, `backend = true` and a `[backend]` block), its
  `dir` is watched too. The backend runs from the directory and is replaced
  when files in `dir` or the `[backend]` block change; changes to pages
  alone leave it running.
  """

  use GenServer

  require Logger

  alias Deepsplay.Backends
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.RevisionFile
  alias Deepsplay.Revisions
  alias Deepsplay.Screen
  alias Deepsplay.Status

  @registry Deepsplay.LocalWatcher.Registry
  @debounce 200
  @retry 2_000

  # FileSystem is a dev and test dependency only, like this feature; calling
  # it through a variable keeps prod builds free of warnings.
  @file_system FileSystem

  @doc false
  def child_spec(%Config{} = config) do
    %{id: {__MODULE__, config.name}, start: {__MODULE__, :start_link, [config]}}
  end

  @doc false
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config,
      name: {:via, Registry, {@registry, config.name, nil}}
    )
  end

  @doc """
  Returns the current version token of the local configuration `name`.
  """
  @spec token(String.t()) :: {:ok, String.t()} | :error
  def token(name) do
    case Registry.lookup(@registry, name) do
      [{_pid, token}] when is_binary(token) -> {:ok, token}
      _other -> :error
    end
  end

  @impl true
  def init(%Config{} = config) do
    root = Screen.root(config.path, config)

    state = %{
      config: config,
      root: root,
      watchers: [],
      timer: nil,
      # The backend (ADR 26): its spec, the watcher of its dir, and a token
      # that changes when it has to be replaced.
      backend: nil,
      backend_watcher: nil,
      backend_token: 0,
      backend_changed: false
    }

    {:ok, state, {:continue, :watch}}
  end

  @impl true
  def handle_continue(:watch, state), do: {:noreply, watch(state)}

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    cond do
      backend_file?(path, state) -> {:noreply, debounce(%{state | backend_changed: true})}
      relevant?(path, state) -> {:noreply, debounce(state)}
      true -> {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    # The watched directory went away; start over once it is back.
    {:noreply, retry(state)}
  end

  def handle_info(:changed, state), do: {:noreply, change(%{state | timer: nil})}
  def handle_info(:retry, state), do: {:noreply, watch(state)}

  defp watch(state) do
    Enum.each(state.watchers, &GenServer.stop(&1, :normal))
    pages = Screen.pages_dir(state.root)
    manifest_dir = Path.dirname(Path.join(state.root, state.config.manifest))

    if File.dir?(pages) and File.dir?(manifest_dir) do
      watchers = [
        start_watcher(dirs: [pages]),
        start_watcher(dirs: [manifest_dir], recursive: false)
      ]

      change(%{state | watchers: watchers})
    else
      record_error(state, "#{state.root} has no #{Screen.pages_dir_name()}/ directory")
      retry(%{state | watchers: []})
    end
  end

  defp start_watcher(opts) do
    {:ok, pid} = apply(@file_system, :start_link, [opts])
    apply(@file_system, :subscribe, [pid])
    pid
  end

  defp retry(state) do
    Process.send_after(self(), :retry, @retry)
    state
  end

  defp debounce(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :changed, @debounce)}
  end

  # Something under pages/ that is not hidden, or the manifest itself.
  defp relevant?(path, state) do
    relative = Path.relative_to(path, state.root)

    case Path.split(relative) do
      [] -> false
      ["pages" | rest] -> not RevisionFile.hidden?(rest)
      _other -> relative == state.config.manifest
    end
  end

  # A new token, announced like a new revision. The manifest is checked so the
  # status shows its errors; the screen shows them as well.
  defp change(state) do
    token = :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)
    Registry.update_value(@registry, state.config.name, fn _old -> token end)

    state =
      case Screen.load(state.root, Screen.options(state.config)) do
        {:ok, screen} ->
          Status.update(state.config.name, %{checked_at: now(), error: nil, error_at: nil})
          sync_backend(state, screen.backend)

        {:error, errors} ->
          record_error(state, Enum.join(errors, "; "))
          state
      end

    Revisions.announce(state.config.name, token)
    %{state | backend_changed: false}
  end

  # Files in the backend's dir, except hidden ones.
  defp backend_file?(_path, %{backend: nil}), do: false

  defp backend_file?(path, state) do
    case Path.split(Path.relative_to(path, Path.join(state.root, state.backend.dir))) do
      ["/" | _absolute] -> false
      [".." | _outside] -> false
      parts -> not RevisionFile.hidden?(parts)
    end
  end

  defp sync_backend(state, nil) do
    if state.backend, do: Backends.stop(state.config.name)
    stop_backend_watcher(state)
    %{state | backend: nil, backend_watcher: nil}
  end

  defp sync_backend(state, spec) do
    state =
      if state.backend && state.backend.dir == spec.dir,
        do: state,
        else: %{stop_backend_watcher(state) | backend_watcher: watch_backend(state, spec)}

    token =
      if state.backend_changed or state.backend != spec,
        do: state.backend_token + 1,
        else: state.backend_token

    start_backend(state, spec, token)
    %{state | backend: spec, backend_token: token}
  end

  defp watch_backend(state, spec) do
    dir = Path.join(state.root, spec.dir)
    if File.dir?(dir), do: start_watcher(dirs: [dir])
  end

  defp stop_backend_watcher(%{backend_watcher: nil} = state), do: state

  defp stop_backend_watcher(state) do
    GenServer.stop(state.backend_watcher, :normal)
    %{state | backend_watcher: nil}
  end

  # Starting can take a while (uv sync), so it runs beside the watcher;
  # Backends keeps a running backend with the same token.
  defp start_backend(state, spec, token) do
    %{config: config, root: root} = state

    Task.start(fn ->
      case Backends.ensure(config, "local-#{token}", root, spec) do
        :ok -> :ok
        {:error, message} -> record_error(state, "backend: " <> message)
      end
    end)
  end

  defp record_error(state, message) do
    Logger.warning(~s(config "#{state.config.name}": #{message}))
    Status.update(state.config.name, %{checked_at: now(), error: message, error_at: now()})
  end

  defp now, do: DateTime.utc_now()
end
