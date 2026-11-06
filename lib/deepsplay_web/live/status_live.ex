defmodule DeepsplayWeb.StatusLive do
  @moduledoc """
  The status page at `/status`: every configuration with its current revision,
  last and next check and last error; the connected screens; and the most
  recent errors. It updates live.

  There are no alerts and no login; the page is meant for the internal network.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl
  alias Deepsplay.Revisions
  alias Deepsplay.Status
  alias DeepsplayWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Status.subscribe_all()
      Phoenix.PubSub.subscribe(Deepsplay.PubSub, Presence.topic())
    end

    {:ok, socket |> assign(page_title: "Status") |> load()}
  end

  @impl true
  def handle_info({:status_changed, _name}, socket), do: {:noreply, load(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket)}

  defp load(socket) do
    assign(socket,
      host_config: Store.get(),
      configs: configs(),
      screens: screens(),
      errors: Status.recent_errors()
    )
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

  defp screens do
    Presence.list(Presence.topic())
    |> Enum.flat_map(fn {id, %{metas: metas}} -> Enum.map(metas, &Map.put(&1, :id, id)) end)
    |> Enum.sort_by(&{&1.config || "", &1.label || "", DateTime.to_unix(&1.connected_at)})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-semibold tracking-tight">Status</h1>

      <section :if={match?({:error, _}, @host_config)} id="status-host-config-error">
        <h2 class="text-lg font-semibold text-red-500">Host configuration unusable</h2>
        <ul class="mt-2 space-y-1 font-mono text-sm">
          <li :for={error <- elem(@host_config, 1)}>{error}</li>
        </ul>
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

  defp warnings({:ok, current}), do: current.screen.warnings
  defp warnings({:error, errors}), do: errors
  defp warnings(:none), do: []

  defp short(nil), do: ""
  defp short(sha), do: String.slice(sha, 0, 12)

  defp state(:playing), do: "playing"
  defp state(:no_revision), do: "waiting for content"
  defp state(:pinned_missing), do: "page not found"
  defp state(:revision_error), do: "revision unusable"
  defp state(:unknown_config), do: "unknown configuration"
  defp state(:host_config), do: "host configuration error"
  defp state(other), do: to_string(other)

  defp time(nil), do: "–"

  defp time(%DateTime{} = time),
    do: time |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
end
