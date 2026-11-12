defmodule DeepsplayWeb.StatusLive do
  @moduledoc """
  The status page at `/status`: every configuration with its current revision,
  last and next check and last error; the connected screens; the upstreams
  with their cache (ADR 20); the namespaces of shared state (ADR 21); the
  backends of configurations (ADR 26); and the
  most recent errors. It updates live; upstream counters and shared state
  every few seconds.

  There are no alerts and no login; the page is meant for the internal network.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.ByteSize

  alias Deepsplay.Backends
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.HostConfig.Watcher
  alias Deepsplay.PageParams
  alias Deepsplay.RepoUrl
  alias Deepsplay.Revisions
  alias Deepsplay.State
  alias Deepsplay.Status
  alias Deepsplay.UpstreamProxy
  alias Deepsplay.UpstreamProxy.Cache
  alias Deepsplay.UpstreamProxy.Stats
  alias DeepsplayWeb.Interrupts
  alias DeepsplayWeb.Mqtt
  alias DeepsplayWeb.Presence

  @upstream_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Status.subscribe_all()
      Phoenix.PubSub.subscribe(Deepsplay.PubSub, Presence.topic())
      :timer.send_interval(@upstream_interval, :upstreams)
      Watcher.subscribe()
      Mqtt.subscribe()
    end

    {:ok, socket |> assign(page_title: "Status") |> load()}
  end

  @impl true
  def handle_info({:status_changed, _name}, socket), do: {:noreply, load(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket)}

  def handle_info(:upstreams, socket), do: {:noreply, assign_upstreams(socket)}

  def handle_info({:host_config_changed}, socket), do: {:noreply, load(socket)}
  def handle_info({:mqtt_changed}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    configs = configs()

    assign(socket,
      host_config: Store.get(),
      reload: Watcher.info(),
      configs: configs,
      interrupts: interrupts(configs),
      mqtt: mqtt(),
      screens: screens(),
      errors: Status.recent_errors()
    )
    |> assign_upstreams()
  end

  defp assign_upstreams(socket),
    do:
      assign(socket,
        upstreams: upstreams(),
        cache_size: Cache.size(),
        states: states(),
        backends: backends()
      )

  # Configurations that allow backends, with their running backend if any.
  defp backends do
    running = Backends.all()

    case Store.get() do
      {:ok, host_config} ->
        for {name, config} <- Enum.sort(host_config.configs), config.backend or running[name] do
          %{name: name, backend: running[name], status: Status.get(name)}
        end

      {:error, _errors} ->
        []
    end
  end

  # Namespaces with values, with the configurations using them; a namespace
  # no configuration uses any more is listed too.
  defp states do
    users =
      case Store.get() do
        {:ok, host_config} ->
          host_config.configs
          |> Map.values()
          |> Enum.sort_by(& &1.name)
          |> Enum.group_by(&State.namespace(host_config, &1), & &1.name)

        {:error, _errors} ->
          %{}
      end

    for info <- State.namespaces(),
        do: Map.put(info, :configs, Map.get(users, info.namespace, []))
  end

  # Host upstreams, then upstreams declared in manifests, grouped by target as
  # their cache entries are.
  defp upstreams do
    case Store.get() do
      {:ok, host_config} ->
        groups = Cache.groups()
        configs = host_config.configs |> Map.values() |> Enum.sort_by(& &1.name)

        host =
          for {name, upstream} <- Enum.sort(host_config.upstreams) do
            used_by = for config <- configs, name in config.upstreams, do: config.name
            row(upstream, "host configuration", used_by, groups)
          end

        manifest =
          configs
          |> Enum.flat_map(fn config ->
            for {_name, upstream} <- Revisions.manifest_upstreams(config),
                do: {upstream, config.name}
          end)
          |> Enum.group_by(fn {upstream, _config} -> upstream.base_url end)
          |> Enum.sort()
          |> Enum.map(fn {_url, [{upstream, _config} | _rest] = declared} ->
            used_by = Enum.map(declared, fn {_upstream, config} -> config end) |> Enum.uniq()
            row(upstream, "manifest", used_by, groups)
          end)

        host ++ manifest

      {:error, _errors} ->
        []
    end
  end

  defp row(upstream, origin, used_by, groups) do
    group = UpstreamProxy.stats_group(upstream)

    %{
      id: "upstream-" <> String.replace("#{origin}-#{upstream.name}", ~r/[^A-Za-z0-9]+/, "-"),
      upstream: upstream,
      origin: origin,
      used_by: used_by,
      cache: Map.get(groups, group, %{entries: 0, size: 0}),
      stats: Stats.get(group)
    }
  end

  defp configs do
    case Store.get() do
      {:ok, host_config} ->
        host_config.configs
        |> Map.values()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn config ->
          %{
            config: config,
            default: config.name == host_config.default_config,
            current: Revisions.current(config),
            status: Status.get(config.name)
          }
        end)

      {:error, _errors} ->
        []
    end
  end

  # The MQTT connection (ADR 33) with the configurations of each filter.
  defp mqtt do
    with %{} = info <- Mqtt.info(),
         {:ok, host_config} <- Store.get() do
      users =
        for {name, %{mqtt_topic: filter}} <- host_config.configs, filter != nil, reduce: %{} do
          users -> Map.update(users, filter, [name], &Enum.sort([name | &1]))
        end

      filters =
        users
        |> Enum.sort()
        |> Enum.map(fn {filter, names} ->
          %{filter: filter, configs: names, subscribed: filter in info.filters}
        end)

      Map.put(info, :filters, filters)
    else
      _none -> nil
    end
  catch
    :exit, _not_running -> nil
  end

  # Interrupts of the current revisions with their last trigger (ADR 32).
  defp interrupts(configs) do
    for row <- configs,
        {:ok, current} <- [row.current],
        last = Interrupts.last(row.config.name),
        interrupt <- current.screen.interrupts do
      %{
        config: row.config.name,
        name: interrupt.name,
        priority: interrupt.priority,
        last: last[interrupt.name]
      }
    end
  end

  defp screens do
    Presence.list(Presence.topic())
    |> Enum.flat_map(fn {id, %{metas: metas}} -> Enum.map(metas, &Map.put(&1, :id, id)) end)
    |> Enum.sort_by(&{&1.config || "", &1.label || "", DateTime.to_unix(&1.connected_at)})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-baseline justify-between gap-4">
        <h1 class="text-2xl font-semibold tracking-tight">Status</h1>
        <div class="flex items-baseline gap-4">
          <.link navigate={~p"/catalog"} id="status-catalog-link" class="text-sm hover:underline">
            Catalog
          </.link>
          <p id="status-version" class="font-mono text-sm text-base-content/60">
            deepsplay {version()}
          </p>
        </div>
      </div>

      <section :if={match?({:error, _}, @host_config)} id="status-host-config-error">
        <h2 class="text-lg font-semibold text-red-500">Host configuration unusable</h2>
        <ul class="mt-2 space-y-1 font-mono text-sm">
          <li :for={error <- elem(@host_config, 1)}>{error}</li>
        </ul>
      </section>

      <section :if={@reload} id="status-host-config" class="text-sm">
        <p class="text-base-content/60">
          Host configuration loaded {time(@reload.loaded_at)}<span :if={@reload.changes != []}>: {Enum.join(
            @reload.changes,
            "; "
          )}</span>
        </p>
        <div
          :if={@reload.rejected}
          id="status-host-config-rejected"
          class="mt-2 border-l-2 border-red-500/60 pl-3"
        >
          <p class="font-medium text-red-500">
            Changed version rejected {time(@reload.rejected.at)}; the last good one keeps running:
          </p>
          <ul class="mt-1 space-y-1 font-mono text-xs">
            <li :for={error <- @reload.rejected.errors}>{error}</li>
          </ul>
        </div>
        <p
          :if={@reload.restart_needed != []}
          id="status-host-config-restart"
          class="mt-2 text-amber-500"
        >
          Restart needed to apply: {Enum.join(@reload.restart_needed, ", ")}
        </p>
      </section>

      <section id="status-configs">
        <h2 class="text-lg font-semibold">Configurations</h2>
        <div class="mt-3 overflow-x-auto rounded-lg border border-base-300">
          <table class="w-full text-left text-sm">
            <thead class="bg-base-200 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2">Name</th>
                <th class="px-3 py-2">Source</th>
                <th class="px-3 py-2">Revision</th>
                <th class="px-3 py-2">Last check</th>
                <th class="px-3 py-2">Next check</th>
                <th class="px-3 py-2">Problems</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @configs}
                id={"config-#{row.config.name}"}
                class="border-t border-base-300 align-top"
              >
                <td class="px-3 py-2 font-medium">
                  <.link navigate={~p"/c/#{row.config.name}"} class="hover:underline">
                    {row.config.name}
                  </.link>
                  <span :if={row.default} class="ml-1 text-xs text-base-content/50">default</span>
                  <div
                    :if={row.config.description}
                    class="config-description max-w-xs text-xs font-normal text-base-content/60"
                  >
                    {row.config.description}
                  </div>
                  <div class="config-screens text-xs font-normal text-base-content/60">
                    {count(Enum.count(@screens, &(&1.config == row.config.name)), "screen", "screens")}
                  </div>
                  <div>
                    <.link navigate={~p"/catalog/#{row.config.name}"} class="text-xs hover:underline">
                      catalog
                    </.link>
                  </div>
                </td>
                <td class="px-3 py-2 font-mono text-xs">
                  <%= if row.config.path do %>
                    <div class="break-all">{row.config.path}</div>
                    <div class="text-base-content/50">local directory</div>
                  <% else %>
                    <div class="break-all">{RepoUrl.redact(row.config.repo)}</div>
                    <div class="text-base-content/50">{row.config.ref}</div>
                  <% end %>
                </td>
                <td class="px-3 py-2">
                  <.revision current={row.current} />
                </td>
                <td class="px-3 py-2 whitespace-nowrap">{time(row.status.checked_at)}</td>
                <td class="px-3 py-2 whitespace-nowrap">{time(row.status.next_check_at)}</td>
                <td class="px-3 py-2">
                  <p :if={row.status.error} class="config-error text-red-500">
                    {row.status.error}
                    <span class="text-xs text-base-content/50">({time(row.status.error_at)})</span>
                  </p>
                  <p :for={warning <- warnings(row.current)} class="config-warning text-amber-500">
                    {warning}
                  </p>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@mqtt} id="status-mqtt" class="text-sm">
        <h2 class="text-lg font-semibold">MQTT</h2>
        <div class="mt-3 rounded-lg border border-base-300 p-4">
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <span class="font-mono">
              {if @mqtt.tls, do: "mqtts", else: "mqtt"}://{@mqtt.broker}
            </span>
            <span class={[
              "mqtt-state text-xs",
              @mqtt.state == :connected && "text-green-600",
              @mqtt.state == :connecting && "text-base-content/60",
              @mqtt.state == :waiting && "text-amber-500"
            ]}>
              {mqtt_state(@mqtt.state)} since {time(@mqtt.since)}
            </span>
          </div>
          <p :if={!@mqtt.tls} class="mt-1 text-xs text-amber-500">
            Plain MQTT: user name and password travel unencrypted.
          </p>
          <p :if={@mqtt.last_error} class="mqtt-error mt-1 text-xs text-red-500">
            {@mqtt.last_error}
          </p>
          <ul class="mt-2 space-y-1 text-xs">
            <li :for={row <- @mqtt.filters} class="mqtt-filter">
              <span class="font-mono">{row.filter}</span>
              <span class="text-base-content/60">· {Enum.join(row.configs, ", ")}</span>
              <span :if={!row.subscribed} class="text-base-content/50">· not subscribed</span>
            </li>
            <li :if={@mqtt.filters == []} class="text-base-content/60">
              No configuration has an <span class="font-mono">mqtt_topic</span>.
            </li>
          </ul>
        </div>
      </section>

      <section :if={@interrupts != []} id="status-interrupts">
        <h2 class="text-lg font-semibold">Interrupts</h2>
        <p class="mt-1 text-xs text-base-content/50">
          The last trigger of each interrupt since the start; screens counts those that got
          the event (connected, not pinned).
        </p>
        <div class="mt-3 overflow-x-auto rounded-lg border border-base-300">
          <table class="w-full text-left text-sm">
            <thead class="bg-base-200 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2">Configuration</th>
                <th class="px-3 py-2">Interrupt</th>
                <th class="px-3 py-2">Priority</th>
                <th class="px-3 py-2">Last trigger</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @interrupts}
                id={"interrupt-#{row.config}-#{row.name}"}
                class="border-t border-base-300 align-top"
              >
                <td class="px-3 py-2">{row.config}</td>
                <td class="px-3 py-2 font-medium">{row.name}</td>
                <td class="px-3 py-2">{row.priority}</td>
                <td class="px-3 py-2 text-xs">
                  {if row.last, do: Interrupts.describe(row.last), else: "–"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="status-screens">
        <h2 class="text-lg font-semibold">
          Screens <span class="text-base-content/50">({length(@screens)})</span>
        </h2>
        <p :if={@screens == []} class="mt-2 text-sm text-base-content/60">No screen is connected.</p>
        <div :if={@screens != []} class="mt-3 overflow-x-auto rounded-lg border border-base-300">
          <table class="w-full text-left text-sm">
            <thead class="bg-base-200 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2">Screen</th>
                <th class="px-3 py-2">Configuration</th>
                <th class="px-3 py-2">State</th>
                <th class="px-3 py-2">Page</th>
                <th class="px-3 py-2">Connected</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={screen <- @screens} id={screen.id} class="border-t border-base-300 align-top">
                <td class="px-3 py-2">
                  <div class="font-medium">{screen.label || screen.ip || "unknown"}</div>
                  <div
                    class="max-w-xs truncate text-xs text-base-content/50"
                    title={screen.user_agent}
                  >
                    {if screen.label, do: screen.ip}
                  </div>
                </td>
                <td class="px-3 py-2">{screen.config}</td>
                <td class="px-3 py-2">
                  {state(screen.state)}
                  <span :if={screen.sha} class="font-mono text-xs text-base-content/50">
                    {short(screen.sha)}
                  </span>
                </td>
                <td class="px-3 py-2 font-mono text-xs">
                  <div class="break-all">{screen.page}</div>
                  <div :if={screen.page_since} class="text-base-content/50">
                    since {time(screen.page_since)}
                  </div>
                </td>
                <td class="px-3 py-2 whitespace-nowrap">{time(screen.connected_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="status-upstreams">
        <h2 class="text-lg font-semibold">
          Upstreams
          <span class="text-sm font-normal text-base-content/50">
            cache {bytes(@cache_size.size)} of {bytes(@cache_size.max_size)}
          </span>
        </h2>
        <p :if={@upstreams == []} class="mt-2 text-sm text-base-content/60">No upstreams.</p>
        <div :if={@upstreams != []} class="mt-3 overflow-x-auto rounded-lg border border-base-300">
          <table class="w-full text-left text-sm">
            <thead class="bg-base-200 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2">Upstream</th>
                <th class="px-3 py-2">Defined in</th>
                <th class="px-3 py-2">Cache</th>
                <th class="px-3 py-2">Answers</th>
                <th class="px-3 py-2">Last call</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @upstreams} id={row.id} class="border-t border-base-300 align-top">
                <td class="px-3 py-2">
                  <div class="font-medium">{row.upstream.name}</div>
                  <div class="break-all font-mono text-xs text-base-content/50">
                    {row.upstream.base_url}
                  </div>
                  <div
                    :if={row.upstream.description}
                    class="upstream-description max-w-xs text-xs text-base-content/60"
                  >
                    {row.upstream.description}
                  </div>
                </td>
                <td class="px-3 py-2">
                  <div>{row.origin}</div>
                  <div class="text-xs text-base-content/50">
                    {if row.used_by == [], do: "no configuration", else: Enum.join(row.used_by, ", ")}
                  </div>
                </td>
                <td class="px-3 py-2 whitespace-nowrap">
                  <%= if row.upstream.cache_ttl do %>
                    <div class="upstream-cache">
                      {count(row.cache.entries, "entry", "entries")}, {bytes(row.cache.size)}<span :if={
                        row.upstream.cache_size
                      }> of {bytes(row.upstream.cache_size)}</span>
                    </div>
                    <div class="text-xs text-base-content/50">
                      {PageParams.format_duration(row.upstream.cache_ttl)}<span :if={
                        row.upstream.stale_ttl
                      }>, stale {PageParams.format_duration(row.upstream.stale_ttl)}</span><span :if={
                        row.upstream.refresh
                      }>, refresh</span>
                    </div>
                    <div
                      :if={row.upstream.accepted_types}
                      class="upstream-types font-mono text-xs text-base-content/50"
                    >
                      {Enum.join(row.upstream.accepted_types, ", ")}
                    </div>
                  <% else %>
                    <span class="text-base-content/50">not cached</span>
                  <% end %>
                </td>
                <td class="upstream-answers px-3 py-2 whitespace-nowrap">
                  {row.stats.hits} hits, {row.stats.misses} misses, {row.stats.stale} stale
                </td>
                <td class="px-3 py-2">
                  <div class="whitespace-nowrap">{time(row.stats.last_fetch_at)}</div>
                  <div :if={row.stats.last_error} class="upstream-error text-xs text-red-500">
                    {time(row.stats.last_error_at)}: {row.stats.last_error}
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="status-state">
        <h2 class="text-lg font-semibold">Shared state</h2>
        <p :if={@states == []} class="mt-2 text-sm text-base-content/60">No shared state.</p>
        <div :if={@states != []} class="mt-3 overflow-x-auto rounded-lg border border-base-300">
          <table class="w-full text-left text-sm">
            <thead class="bg-base-200 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-3 py-2">Namespace</th>
                <th class="px-3 py-2">Configurations</th>
                <th class="px-3 py-2">Keys</th>
                <th class="px-3 py-2">Last write</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{info, index} <- Enum.with_index(@states)}
                id={"state-#{index}"}
                class="border-t border-base-300 align-top"
              >
                <td class="px-3 py-2 break-all font-mono text-xs">{info.namespace}</td>
                <td class="px-3 py-2">
                  {if info.configs == [], do: "no configuration", else: Enum.join(info.configs, ", ")}
                </td>
                <td class="state-keys px-3 py-2 whitespace-nowrap">
                  {count(info.keys, "key", "keys")}, {bytes(info.size)}
                </td>
                <td class="px-3 py-2 whitespace-nowrap">{time(info.written_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@backends != []} id="status-backends">
        <h2 class="text-lg font-semibold">Backends</h2>
        <div
          :for={row <- @backends}
          id={"backend-#{row.name}"}
          class="mt-3 rounded-lg border border-base-300 p-4 text-sm"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <span class="font-medium">{row.name}</span>
            <%= if row.backend do %>
              <span class="backend-state font-mono text-xs">
                {row.backend.info.state} · revision {short(row.backend.sha)} · port {row.backend.info.port}
              </span>
            <% else %>
              <span class="backend-state text-xs text-base-content/50">not running</span>
            <% end %>
          </div>
          <%= if row.backend do %>
            <p class="mt-1 text-xs text-base-content/60">
              started {time(row.backend.info.started_at)} · {count(
                row.backend.info.restarts,
                "restart",
                "restarts"
              )}
            </p>
            <p :if={row.backend.info.error} class="backend-error mt-1 text-xs text-red-500">
              {row.backend.info.error}
            </p>
            <p
              :if={row.backend.info.last_crash && !row.backend.info.error}
              class="mt-1 text-xs text-amber-500"
            >
              last crash: {row.backend.info.last_crash}
            </p>
            <details :if={row.backend.info.output != []} class="mt-2">
              <summary class="cursor-pointer text-xs text-base-content/60">Recent output</summary>
              <pre class="backend-output mt-1 max-h-64 overflow-auto rounded bg-base-200 p-2 text-xs"><%= Enum.join(row.backend.info.output, "\n") %></pre>
            </details>
          <% else %>
            <p :if={row.status.error} class="backend-error mt-1 text-xs text-red-500">
              {row.status.error}
            </p>
          <% end %>
        </div>
      </section>

      <section id="status-errors">
        <h2 class="text-lg font-semibold">Recent errors</h2>
        <p :if={@errors == []} class="mt-2 text-sm text-base-content/60">
          No errors since the start.
        </p>
        <ul :if={@errors != []} class="mt-3 space-y-2 text-sm">
          <li :for={entry <- @errors} class="error-entry border-l-2 border-red-500/60 pl-3">
            <span class="text-base-content/50">{time(entry.at)}</span>
            <span class="font-medium">{entry.config}</span>
            <span class="font-mono text-xs">{entry.message}</span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  attr :current, :any, required: true

  defp revision(%{current: {:ok, current}} = assigns) do
    assigns = assign(assigns, current: current)

    ~H"""
    <div class="font-mono text-xs">
      {short(@current.sha)}<span :if={@current.local} class="text-base-content/50"> (live)</span>
    </div>
    <div>{@current.screen.title}</div>
    <div class="text-xs text-base-content/50">
      {length(@current.screen.pages)} pages, {@current.screen.rotation}
    </div>
    """
  end

  defp revision(%{current: :none} = assigns) do
    ~H"""
    <span class="text-base-content/50">none yet</span>
    """
  end

  defp revision(%{current: {:error, _errors}} = assigns) do
    ~H"""
    <span class="text-red-500">unusable</span>
    """
  end

  defp warnings({:ok, current}), do: current.screen.warnings ++ current.param_warnings
  defp warnings({:error, errors}), do: errors
  defp warnings(:none), do: []

  defp version, do: Application.spec(:deepsplay, :vsn) |> to_string()

  defp short(nil), do: ""
  defp short(sha), do: String.slice(sha, 0, 12)

  defp state(:playing), do: "playing"
  defp state(:no_revision), do: "waiting for content"
  defp state(:pinned_missing), do: "page not found"
  defp state(:revision_error), do: "revision unusable"
  defp state(:unknown_config), do: "unknown configuration"
  defp state(:host_config), do: "host configuration error"
  defp state(other), do: to_string(other)

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp bytes(size), do: ByteSize.format(size)

  defp mqtt_state(:connected), do: "connected"
  defp mqtt_state(:connecting), do: "connecting"
  defp mqtt_state(:waiting), do: "waiting to reconnect"

  defp time(nil), do: "–"

  defp time(%DateTime{} = time),
    do: time |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
end
