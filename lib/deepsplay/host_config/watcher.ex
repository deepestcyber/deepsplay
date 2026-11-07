defmodule Deepsplay.HostConfig.Watcher do
  @moduledoc """
  Reloads the host configuration and the secrets file when they change
  (ADR 23).

  Both files are checked every few seconds (`:host_config_interval`, default
  5 seconds) for a changed content hash; `SIGHUP` checks at once. A changed
  version is read completely first:

    * invalid: nothing is applied, the last good version keeps running; the
      errors are logged and kept for the status page until a valid version
      arrives;
    * valid: secrets and host configuration are replaced, pollers and local
      watchers reconciled (`Deepsplay.Pollers.reconcile/2`), the upstream
      cache gets its new size limit, and `{:host_config_changed}` is
      broadcast on `topic/0`, so screens and the status page catch up.

  A changed `cache_dir` or `state_dir` is reported as needing a restart, as
  the stores using them were set up at start.
  """

  use GenServer

  require Logger

  alias Deepsplay.Backends
  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Pollers
  alias Deepsplay.Secrets
  alias Deepsplay.UpstreamProxy.Cache

  @pubsub Deepsplay.PubSub
  @topic "host_config"
  @default_interval 5_000

  @type info :: %{
          loaded_at: DateTime.t(),
          changes: [String.t()],
          rejected: %{errors: [String.t()], at: DateTime.t()} | nil,
          restart_needed: [String.t()]
        }

  @doc false
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The topic on which `{:host_config_changed}` is broadcast."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to host configuration changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc "Checks the files now instead of waiting for the next interval."
  @spec check_now(GenServer.server()) :: :ok
  def check_now(watcher \\ __MODULE__), do: GenServer.call(watcher, :check)

  @doc """
  When the host configuration was loaded, what the last change did, a
  rejected newer version, and settings that need a restart; `nil` if the
  watcher is not running.
  """
  @spec info(GenServer.server()) :: info() | nil
  def info(watcher \\ __MODULE__) do
    GenServer.call(watcher, :info)
  catch
    :exit, _reason -> nil
  end

  @doc """
  What changed between two host configurations, as short lines for the
  status page and the log.
  """
  @spec changes(Store.state(), HostConfig.t()) :: [String.t()]
  def changes({:ok, old}, %HostConfig{} = new) do
    names(old.configs, new.configs, "configuration") ++
      names(old.upstreams, new.upstreams, "upstream") ++
      server_changes(old, new)
  end

  def changes(_unusable, _new), do: ["host configuration is usable again"]

  defp names(old, new, what) do
    added = Map.keys(new) -- Map.keys(old)
    removed = Map.keys(old) -- Map.keys(new)
    changed = for {name, value} <- new, Map.has_key?(old, name), old[name] != value, do: name

    for {verb, list} <- [{"added", added}, {"removed", removed}, {"changed", changed}],
        list != [] do
      "#{what} #{verb}: #{list |> Enum.sort() |> Enum.join(", ")}"
    end
  end

  @server_fields ~w(default_config poll_interval keep_revisions upstream_cache_size
                    repo_upstreams repo_upstream_hosts shared_state cache_dir state_dir)a

  defp server_changes(old, new) do
    case for field <- @server_fields, Map.get(old, field) != Map.get(new, field), do: field do
      [] -> []
      fields -> ["server settings changed: #{Enum.join(fields, ", ")}"]
    end
  end

  # Server

  @impl true
  def init(opts) do
    interval =
      Keyword.get(opts, :interval) ||
        Application.get_env(:deepsplay, :host_config_interval, @default_interval)

    if Keyword.get(opts, :signals, true), do: listen_for_sighup()

    state = %{
      interval: interval,
      hash: files_hash(),
      started: Store.get(),
      secrets: secrets_fingerprint(),
      loaded_at: DateTime.utc_now(),
      changes: [],
      rejected: nil,
      restart_needed: []
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:check, state), do: {:noreply, schedule(check(state))}

  @impl true
  def handle_call(:check, _from, state), do: {:reply, :ok, check(state)}

  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:loaded_at, :changes, :rejected, :restart_needed]), state}
  end

  defp schedule(state) do
    Process.send_after(self(), :check, state.interval)
    state
  end

  defp check(state) do
    case files_hash() do
      hash when hash == state.hash -> state
      hash -> %{reload(state) | hash: hash}
    end
  end

  defp reload(state) do
    case Store.read() do
      {:ok, host_config, secrets} ->
        apply_change(state, host_config, secrets)

      {:error, errors} ->
        Logger.error("changed host configuration rejected:\n  " <> Enum.join(errors, "\n  "))
        broadcast()
        %{state | rejected: %{errors: errors, at: DateTime.utc_now()}}
    end
  end

  defp apply_change(state, host_config, secrets) do
    old = Store.get()
    Secrets.put(secrets)
    Store.put({:ok, host_config})

    secrets_changed = secrets_fingerprint() != state.secrets
    changes = changes(old, host_config) ++ if(secrets_changed, do: ["secrets changed"], else: [])

    Pollers.reconcile(old, {:ok, host_config})
    Backends.keep_only(Map.keys(host_config.configs))
    set_cache_size(host_config.upstream_cache_size)

    Logger.info(
      "host configuration reloaded" <>
        if(changes == [], do: " (no changes)", else: ": " <> Enum.join(changes, "; "))
    )

    broadcast()

    %{
      state
      | secrets: secrets_fingerprint(),
        loaded_at: DateTime.utc_now(),
        changes: changes,
        rejected: nil,
        restart_needed: restart_needed(state.started, host_config)
    }
  end

  defp set_cache_size(size) do
    Cache.set_max_size(size)
  catch
    :exit, _not_running -> :ok
  end

  # Directories of stores set up at start; without a usable start
  # configuration, they were set up without them.
  defp restart_needed({:ok, started}, new) do
    for field <- [:cache_dir, :state_dir],
        Map.get(started, field) != Map.get(new, field),
        do: Atom.to_string(field)
  end

  defp restart_needed(_unusable, _new), do: ["cache_dir", "state_dir"]

  defp broadcast, do: Phoenix.PubSub.broadcast(@pubsub, @topic, {:host_config_changed})

  defp files_hash do
    for key <- [:host_config_path, :secrets_path] do
      with path when is_binary(path) <- Application.get_env(:deepsplay, key),
           {:ok, content} <- File.read(path) do
        :crypto.hash(:sha256, content)
      else
        _missing -> :missing
      end
    end
  end

  defp secrets_fingerprint do
    Secrets.names() |> Enum.map(&{&1, Secrets.fetch(&1)}) |> :erlang.phash2()
  end

  # SIGHUP checks at once. The default handler of the signal server stays in
  # place for the other signals.
  defp listen_for_sighup do
    :os.set_signal(:sighup, :handle)
    :gen_event.add_sup_handler(:erl_signal_server, {__MODULE__.SignalHandler, self()}, self())
  catch
    _kind, _reason -> :ok
  end
end
