defmodule DeepsplayWeb.CatalogLive do
  @moduledoc """
  The page catalog overview at `/catalog` (ADR 17): every configuration with
  its source, current revision, number of pages and warnings, linking to its
  catalog page. Updates live.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.Catalog
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl
  alias Deepsplay.Status

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Status.subscribe_all()
    {:ok, socket |> assign(page_title: "Catalog") |> load()}
  end

  @impl true
  def handle_info({:status_changed, _name}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    case Store.get() do
      {:ok, host_config} ->
        rows =
          host_config.configs
          |> Map.values()
          |> Enum.sort_by(& &1.name)
          |> Enum.map(&{&1, Catalog.for_config(&1)})

        assign(socket, rows: rows, host_errors: nil)

      {:error, errors} ->
        assign(socket, rows: [], host_errors: errors)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-baseline justify-between gap-4">
        <h1 class="text-2xl font-semibold tracking-tight">Catalog</h1>
        <Layouts.page_nav current={:catalog} />
      </div>

      <section :if={@host_errors} id="catalog-host-config-error">
        <h2 class="text-lg font-semibold text-red-500">Host configuration unusable</h2>
        <ul class="mt-2 space-y-1 font-mono text-sm">
          <li :for={error <- @host_errors}>{error}</li>
        </ul>
      </section>

      <div id="catalog-configs" class="grid gap-4 sm:grid-cols-2">
        <.link
          :for={{config, catalog} <- @rows}
          navigate={~p"/catalog/#{config.name}"}
          id={"catalog-config-#{config.name}"}
          class="block rounded-lg border border-base-300 p-4 transition hover:border-base-content/40 hover:bg-base-200/50"
        >
          <div class="flex items-baseline justify-between gap-2">
            <h2 class="font-semibold">{config.name}</h2>
            <span class="font-mono text-xs text-base-content/50">{revision(catalog)}</span>
          </div>
          <p class="mt-1 break-all font-mono text-xs text-base-content/60">{source(config)}</p>
          <p class="mt-3 text-sm">
            <%= case catalog do %>
              <% {:ok, c} -> %>
                {length(c.pages)} files · {length(c.rotation)} in rotation
                <span :if={c.warnings != []} class="ml-2 text-amber-500">
                  {length(c.warnings)} warnings
                </span>
              <% :none -> %>
                <span class="text-base-content/50">no revision yet</span>
              <% {:error, _} -> %>
                <span class="text-red-500">revision unusable</span>
            <% end %>
          </p>
        </.link>
      </div>
    </Layouts.app>
    """
  end

  defp source(%{path: path}) when is_binary(path), do: path <> " (local directory)"
  defp source(config), do: "#{RepoUrl.redact(config.repo)} @ #{config.ref}"

  defp revision({:ok, %{current: current}}) do
    String.slice(current.sha, 0, 12) <> if(current.local, do: " (live)", else: "")
  end

  defp revision(_catalog), do: ""
end
