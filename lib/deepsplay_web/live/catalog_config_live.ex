defmodule DeepsplayWeb.CatalogConfigLive do
  @moduledoc """
  The catalog page of one configuration at `/catalog/<name>` (ADR 17): the
  rotation with the parameters each page gets, all pages with their
  documentation, parameters and variants, the helpers and all warnings.

  One page at a time can be previewed (rendered at a real screen size and
  scaled down) or tried in the playground, a form built from its parameter
  definitions that updates the preview and gives the pinned link.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.ByteSize

  alias Deepsplay.Catalog
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.PageParams
  alias Deepsplay.RepoUrl
  alias Deepsplay.Revisions
  alias Deepsplay.Status
  alias DeepsplayWeb.ScreenPlan

  @sizes [
    {"1920x1080", "Full HD, landscape"},
    {"1080x1920", "Full HD, portrait"},
    {"1080x1080", "Square"},
    {"390x844", "Phone"},
    {"custom", "Custom…"}
  ]

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Status.subscribe_all()

    socket =
      socket
      |> assign(name: name, page_title: "Catalog · #{name}", selected: nil)
      |> assign(size: "1920x1080", width: 1920, height: 1080)
      |> assign(
        size_form: to_form(%{"size" => "1920x1080", "width" => "1920", "height" => "1080"})
      )
      |> load()

    {:ok, socket}
  end

  @impl true
  def handle_info({:status_changed, _name}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    result =
      case Store.lookup(socket.assigns.name) do
        {:ok, config} -> Catalog.for_config(config)
        {:error, :unknown_config} -> {:unknown, nil}
        {:error, {:host_config, errors}} -> {:host_config, errors}
      end

    socket = assign(socket, result: result)

    # Keep the selection while its page still exists.
    case {result, socket.assigns.selected} do
      {{:ok, catalog}, %{path: path}} ->
        if Enum.any?(catalog.pages, &(&1.path == path)),
          do: socket,
          else: assign(socket, selected: nil)

      _other ->
        assign(socket, selected: nil)
    end
  end

  # ---------- events ----------

  @impl true
  def handle_event("preview", %{"path" => path} = params, socket) do
    {:noreply, select(socket, path, params["query"] || "", false)}
  end

  def handle_event("playground", %{"path" => path}, socket) do
    {:noreply, select(socket, path, "", true)}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("playground_change", %{"p" => values}, socket) do
    %{selected: selected} = socket.assigns
    query = playground_query(selected.rows, values, selected.initial)

    {:noreply,
     assign(socket,
       selected: %{selected | query: query, form: to_form(values, as: :p)}
     )}
  end

  def handle_event("size", %{"size" => size} = params, socket) do
    {width, height} =
      case size do
        "custom" ->
          {to_px(params["width"], socket.assigns.width),
           to_px(params["height"], socket.assigns.height)}

        preset ->
          preset |> String.split("x") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
      end

    {:noreply,
     assign(socket,
       size: size,
       width: width,
       height: height,
       size_form:
         to_form(%{"size" => size, "width" => to_string(width), "height" => to_string(height)})
     )}
  end

  defp select(socket, path, query, playground?) do
    {:ok, catalog} = socket.assigns.result
    page = Enum.find(catalog.pages, &(&1.path == path))
    initial = initial_values(page.params)

    assign(socket,
      selected: %{
        path: path,
        query: query,
        playground: playground?,
        rows: page.params,
        initial: initial,
        form: to_form(initial, as: :p)
      }
    )
  end

  defp to_px(value, fallback) do
    case Integer.parse(value || "") do
      {px, ""} when px in 100..8000 -> px
      _other -> fallback
    end
  end

  # ---------- playground ----------

  # Form values a page starts with: empty (the page's own default applies),
  # except colour pickers, which always have a value.
  defp initial_values(rows) do
    Map.new(rows, fn %{param: p} ->
      {p.name, if(p.type == "color", do: color_initial(p.default), else: "")}
    end)
  end

  defp color_initial("#" <> hex = color) when byte_size(hex) == 6, do: color
  defp color_initial(_other), do: "#000000"

  defp playground_query(rows, values, initial) do
    rows
    |> Enum.flat_map(fn %{param: p} ->
      value = Map.get(values, p.name, "")
      if value == "" or value == initial[p.name], do: [], else: [{p.name, value}]
    end)
    |> URI.encode_query()
  end

  # ---------- URLs ----------

  defp preview_url(catalog, path, query) do
    context = Revisions.param_context(catalog.config, catalog.current)
    query = blank_to_nil(query)
    {added, _warnings, _declared} = PageParams.for_page(context, path, query, nil)

    ScreenPlan.page_url(
      catalog.config.name,
      catalog.current.sha,
      path,
      PageParams.merge_query(query, added)
    )
  end

  defp pin_url(name, path, query) do
    page = if blank_to_nil(query), do: path <> "?" <> query, else: path
    "/c/#{URI.encode(name, &URI.char_unreserved?/1)}?" <> URI.encode_query(%{"page" => page})
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(query), do: query

  # ---------- rendering ----------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, sizes: @sizes)

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-baseline justify-between gap-4">
        <h1 class="text-2xl font-semibold tracking-tight">
          <.link navigate={~p"/catalog"} class="text-base-content/50 hover:underline">Catalog</.link>
          <span class="text-base-content/30">/</span> {@name}
        </h1>
        <.link navigate={~p"/status"} class="text-sm text-base-content/60 hover:underline">
          Status
        </.link>
      </div>

      <%= case @result do %>
        <% {:ok, catalog} -> %>
          <.catalog
            catalog={catalog}
            selected={@selected}
            size={@size}
            width={@width}
            height={@height}
            size_form={@size_form}
            sizes={@sizes}
          />
        <% :none -> %>
          <p id="catalog-no-revision" class="text-base-content/60">
            No revision of this configuration is available yet.
          </p>
        <% {:error, errors} -> %>
          <section id="catalog-revision-error">
            <h2 class="font-semibold text-red-500">The current revision is unusable</h2>
            <ul class="mt-2 space-y-1 font-mono text-sm">
              <li :for={error <- errors}>{error}</li>
            </ul>
          </section>
        <% {:unknown, _} -> %>
          <p id="catalog-unknown-config" class="text-base-content/60">
            No configuration named <span class="font-mono">{@name}</span> is defined.
          </p>
        <% {:host_config, errors} -> %>
          <section id="catalog-host-config-error">
            <h2 class="font-semibold text-red-500">Host configuration unusable</h2>
            <ul class="mt-2 space-y-1 font-mono text-sm">
              <li :for={error <- errors}>{error}</li>
            </ul>
          </section>
      <% end %>
    </Layouts.app>
    """
  end

  attr :catalog, :map, required: true
  attr :selected, :map, default: nil
  attr :size, :string, required: true
  attr :width, :integer, required: true
  attr :height, :integer, required: true
  attr :size_form, :any, required: true
  attr :sizes, :list, required: true

  defp catalog(assigns) do
    ~H"""
    <section id="catalog-header" class="rounded-lg border border-base-300 p-4 text-sm">
      <dl class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1">
        <dt class="text-base-content/50">Source</dt>
        <dd class="break-all font-mono text-xs">{source(@catalog.config)}</dd>
        <dt class="text-base-content/50">Revision</dt>
        <dd class="font-mono text-xs">
          {String.slice(@catalog.current.sha, 0, 12)}{if @catalog.current.local, do: " (live)"}
        </dd>
        <dt class="text-base-content/50">Manifest</dt>
        <dd class="font-mono text-xs">
          {@catalog.config.manifest} · {@catalog.current.screen.rotation}
          <span :if={@catalog.current.screen.title}>· {@catalog.current.screen.title}</span>
        </dd>
        <dt class="text-base-content/50">Defaults</dt>
        <dd id="catalog-defaults" class="font-mono text-xs">
          <span :if={defaults(@catalog) == []} class="text-base-content/50">none</span>
          <span :for={{name, value, origin} <- defaults(@catalog)} class="mr-3">
            {name}={value} <span class="text-base-content/50">({origin})</span>
          </span>
        </dd>
      </dl>
    </section>

    <section :if={@catalog.warnings != []} id="catalog-warnings">
      <h2 class="text-lg font-semibold">Warnings</h2>
      <ul class="mt-2 space-y-1 text-sm">
        <li :for={warning <- @catalog.warnings} class="catalog-warning text-amber-500">{warning}</li>
      </ul>
    </section>

    <section id="catalog-rotation">
      <h2 class="text-lg font-semibold">Rotation</h2>
      <div class="mt-3 overflow-x-auto rounded-lg border border-base-300">
        <table class="w-full text-left text-sm">
          <thead class="bg-base-200 text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="px-3 py-2">Page</th>
              <th class="px-3 py-2">Duration</th>
              <th class="px-3 py-2">Weight</th>
              <th class="px-3 py-2">Parameters</th>
              <th class="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{entry, i} <- Enum.with_index(@catalog.rotation)}
              id={"rotation-#{i}"}
              class="border-t border-base-300 align-top"
            >
              <td class="px-3 py-2 font-mono text-xs">{entry.path}</td>
              <td class="px-3 py-2">{PageParams.format_duration(entry.duration)}</td>
              <td class="px-3 py-2">{entry.weight}</td>
              <td class="px-3 py-2 font-mono text-xs">
                <div :for={{name, value, origin} <- entry.params}>
                  {name}={value} <span class="text-base-content/50">({origin})</span>
                </div>
              </td>
              <td class="px-3 py-2 text-right">
                <a
                  href={pin_url(@catalog.config.name, entry.path, entry.query || "")}
                  target="_blank"
                  class="text-xs hover:underline"
                >pin ↗</a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section id="catalog-pages">
      <h2 class="text-lg font-semibold">Pages</h2>
      <div class="mt-3 space-y-3">
        <.page_card
          :for={page <- @catalog.pages}
          page={page}
          catalog={@catalog}
          selected={@selected}
          size={@size}
          width={@width}
          height={@height}
          size_form={@size_form}
          sizes={@sizes}
        />
      </div>
    </section>

    <section id="catalog-helpers">
      <h2 class="text-lg font-semibold">Helpers</h2>
      <p :if={@catalog.helpers == []} class="mt-2 text-sm text-base-content/60">No helpers.</p>
      <div
        :for={helper <- @catalog.helpers}
        id={"helper-#{helper.name}"}
        class="mt-3 rounded-lg border border-base-300 p-4 text-sm"
      >
        <div class="flex items-baseline justify-between gap-2">
          <h3 class="font-semibold">{helper.name}</h3>
          <span class="font-mono text-xs text-base-content/50">{helper.file}</span>
        </div>
        <p :if={helper.description} class="mt-1 text-base-content/70">{helper.description}</p>
        <p class="mt-2 font-mono text-xs">
          {helper.params |> Map.keys() |> Enum.sort() |> Enum.join(", ")}
        </p>
        <p class="mt-1 text-xs text-base-content/50">
          Used by: {if helper.used_by == [], do: "no page", else: Enum.join(helper.used_by, ", ")}
        </p>
      </div>
    </section>

    <section :if={@catalog.state} id="catalog-state">
      <h2 class="text-lg font-semibold">Shared state</h2>
      <p class="mt-1 break-all font-mono text-xs text-base-content/50">
        {@catalog.state.namespace}
      </p>
      <p :if={@catalog.state.total == 0} class="mt-2 text-sm text-base-content/60">No values.</p>
      <div
        :if={@catalog.state.total > 0}
        class="mt-3 overflow-x-auto rounded-lg border border-base-300"
      >
        <table class="w-full text-left text-sm">
          <thead class="bg-base-200 text-xs uppercase tracking-wide text-base-content/60">
            <tr>
              <th class="px-3 py-2">Key</th>
              <th class="px-3 py-2">Version</th>
              <th class="px-3 py-2">Value</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @catalog.state.entries} class="state-entry border-t border-base-300">
              <td class="px-3 py-2 font-mono text-xs">{entry.key}</td>
              <td class="px-3 py-2 font-mono text-xs">{entry.version}</td>
              <td class="px-3 py-2 break-all font-mono text-xs">{entry.value}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p
        :if={@catalog.state.total > length(@catalog.state.entries)}
        class="mt-2 text-xs text-base-content/50"
      >
        and {@catalog.state.total - length(@catalog.state.entries)} more
      </p>
    </section>

    <section :if={@catalog.upstreams != []} id="catalog-upstreams">
      <h2 class="text-lg font-semibold">Upstreams in the manifest</h2>
      <div
        :for={%{upstream: upstream, used_by: used_by} <- @catalog.upstreams}
        id={"upstream-#{upstream.name}"}
        class="mt-3 rounded-lg border border-base-300 p-4 text-sm"
      >
        <div class="flex items-baseline justify-between gap-2">
          <h3 class="font-semibold">{upstream.name}</h3>
          <span class="font-mono text-xs text-base-content/50 break-all">{upstream.base_url}</span>
        </div>
        <p class="mt-2 font-mono text-xs">
          cache {PageParams.format_duration(upstream.cache_ttl)}
          <span :if={upstream.stale_ttl}>
            · stale {PageParams.format_duration(upstream.stale_ttl)}
          </span>
          <span :if={upstream.refresh}>· refresh</span>
          <span :if={upstream.cache_size}>· at most {bytes(upstream.cache_size)}</span>
        </p>
        <p :if={upstream.accepted_types} class="mt-1 font-mono text-xs text-base-content/60">
          accepts {Enum.join(upstream.accepted_types, ", ")}
        </p>
        <p class="mt-1 text-xs text-base-content/50">
          Used by: {if used_by == [], do: "no page", else: Enum.join(used_by, ", ")}
        </p>
      </div>
    </section>
    """
  end

  attr :page, :map, required: true
  attr :catalog, :map, required: true
  attr :selected, :map, default: nil
  attr :size, :string, required: true
  attr :width, :integer, required: true
  attr :height, :integer, required: true
  attr :size_form, :any, required: true
  attr :sizes, :list, required: true

  defp page_card(assigns) do
    assigns =
      assign(assigns,
        active: assigns.selected && assigns.selected.path == assigns.page.path,
        id: "page-" <> String.replace(assigns.page.path, ~r/[^A-Za-z0-9]+/, "-")
      )

    ~H"""
    <article
      id={@id}
      class={[
        "rounded-lg border p-4 text-sm transition",
        if(@active, do: "border-base-content/40", else: "border-base-300")
      ]}
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <div>
          <h3 class="font-semibold">{page_title(@page)}</h3>
          <span class="font-mono text-xs text-base-content/50">{@page.path}</span>
          <span :if={@page.kind == :fragment} class="ml-2 text-xs text-base-content/50">
            not a page
          </span>
          <span :if={@page.kind == :undocumented} class="ml-2 text-xs text-base-content/50">
            undocumented
          </span>
        </div>
        <div :if={@page.kind != :fragment} class="flex gap-3 text-xs">
          <button
            type="button"
            phx-click="preview"
            phx-value-path={@page.path}
            class="page-preview hover:underline"
          >preview</button>
          <button
            :if={@page.params != []}
            type="button"
            phx-click="playground"
            phx-value-path={@page.path}
            class="page-playground hover:underline"
          >playground</button>
          <a
            href={pin_url(@catalog.config.name, @page.path, "")}
            target="_blank"
            class="hover:underline"
          >pin ↗</a>
        </div>
      </div>

      <p
        :if={@page.doc && @page.doc.description}
        class="mt-2 whitespace-pre-line text-base-content/70"
      >
        {String.trim(@page.doc.description)}
      </p>
      <p :if={@page.doc && @page.doc.uses != []} class="mt-1 text-xs text-base-content/50">
        Uses: {Enum.join(@page.doc.uses, ", ")}
      </p>

      <ul :if={@page.warnings != []} class="mt-2 space-y-1 text-xs">
        <li :for={w <- @page.warnings} class="text-amber-500">{w}</li>
      </ul>

      <div :if={@page.params != []} class="mt-3 overflow-x-auto">
        <table class="w-full text-left text-xs">
          <thead class="text-base-content/50">
            <tr>
              <th class="py-1 pr-3">Parameter</th>
              <th class="py-1 pr-3">Type</th>
              <th class="py-1 pr-3">Default</th>
              <th class="py-1 pr-3">Here</th>
              <th class="py-1">Description</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @page.params} class="border-t border-base-300 align-top">
              <td class="py-1 pr-3 font-mono">
                {row.param.name}
                <span :if={row.origin != :page} class="text-base-content/50">
                  ({elem(row.origin, 1)})
                </span>
              </td>
              <td class="py-1 pr-3">{type_text(row.param)}</td>
              <td class="py-1 pr-3 font-mono">{format_value(row.param, row.param.default)}</td>
              <td class="py-1 pr-3 font-mono">
                <span :if={row.value}>{row.value}
                <span class="text-base-content/50">({row.value_origin})</span></span>
              </td>
              <td class="py-1">{row.param.description}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@page.doc && @page.doc.variants != []} class="mt-3 flex flex-wrap gap-2 text-xs">
        <span class="text-base-content/50">Variants:</span>
        <span :for={variant <- @page.doc.variants} class="inline-flex gap-1">
          <button
            type="button"
            phx-click="preview"
            phx-value-path={@page.path}
            phx-value-query={variant.query}
            class="page-variant hover:underline"
          >{variant.label}</button>
          <a
            href={pin_url(@catalog.config.name, @page.path, variant.query)}
            target="_blank"
            class="text-base-content/50 hover:underline"
          >↗</a>
        </span>
      </div>

      <.preview
        :if={@active}
        page={@page}
        catalog={@catalog}
        selected={@selected}
        size={@size}
        width={@width}
        height={@height}
        size_form={@size_form}
        sizes={@sizes}
      />
    </article>
    """
  end

  attr :page, :map, required: true
  attr :catalog, :map, required: true
  attr :selected, :map, required: true
  attr :size, :string, required: true
  attr :width, :integer, required: true
  attr :height, :integer, required: true
  attr :size_form, :any, required: true
  attr :sizes, :list, required: true

  defp preview(assigns) do
    assigns =
      assign(assigns,
        url: preview_url(assigns.catalog, assigns.page.path, assigns.selected.query),
        pin: pin_url(assigns.catalog.config.name, assigns.page.path, assigns.selected.query)
      )

    ~H"""
    <div id="catalog-preview" class="mt-4 space-y-3 border-t border-base-300 pt-4">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <.form for={@size_form} id="preview-size" phx-change="size" class="flex items-end gap-2">
          <.input
            type="select"
            field={@size_form[:size]}
            label="Size"
            options={Enum.map(@sizes, fn {value, label} -> {label, value} end)}
          />
          <%= if @size == "custom" do %>
            <.input type="number" field={@size_form[:width]} label="Width" min="100" max="8000" />
            <.input type="number" field={@size_form[:height]} label="Height" min="100" max="8000" />
          <% end %>
        </.form>
        <div class="flex items-center gap-3 text-xs">
          <a id="preview-pin" href={@pin} target="_blank" class="font-mono hover:underline">{@pin} ↗</a>
          <button type="button" phx-click="close" class="hover:underline">close</button>
        </div>
      </div>

      <.form
        :if={@selected.playground}
        for={@selected.form}
        id="playground-form"
        phx-change="playground_change"
        class="grid gap-x-4 gap-y-1 sm:grid-cols-2 lg:grid-cols-3"
      >
        <.playground_field :for={row <- @selected.rows} row={row} form={@selected.form} />
      </.form>

      <div
        id="preview-frame"
        phx-hook=".FitFrame"
        data-width={@width}
        data-height={@height}
        class="flex h-[70vh] items-center justify-center rounded-lg bg-base-200"
      >
        <div class="preview-box relative overflow-hidden rounded shadow">
          <iframe
            id="preview-iframe"
            src={@url}
            title="Preview"
            class="absolute left-0 top-0 origin-top-left border-0 bg-white"
            style={"width: #{@width}px; height: #{@height}px"}
          ></iframe>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FitFrame">
        // Scales the page, rendered at the chosen screen size, to fit the area.
        export default {
          mounted() {
            this.observer = new ResizeObserver(() => this.fit())
            this.observer.observe(this.el)
            this.fit()
          },
          updated() { this.fit() },
          destroyed() { this.observer.disconnect() },
          fit() {
            const width = Number(this.el.dataset.width), height = Number(this.el.dataset.height)
            const scale = Math.min(this.el.clientWidth / width, this.el.clientHeight / height, 1)
            const box = this.el.querySelector(".preview-box")
            const frame = this.el.querySelector("iframe")
            box.style.width = `${width * scale}px`
            box.style.height = `${height * scale}px`
            frame.style.transform = `scale(${scale})`
          },
        }
      </script>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :form, :any, required: true

  defp playground_field(%{row: %{param: param}} = assigns) do
    assigns = assign(assigns, param: param, field: assigns.form[param.name])

    ~H"""
    <%= case @param.type do %>
      <% "enum" -> %>
        <.input
          type="select"
          field={@field}
          label={@param.name}
          options={[{"(default)", ""} | Enum.map(@param.values, &{&1, &1})]}
        />
      <% "bool" -> %>
        <.input
          type="select"
          field={@field}
          label={@param.name}
          options={[{"(default)", ""}, {"on", "true"}, {"off", "false"}]}
        />
      <% "int" -> %>
        <.input
          type="number"
          field={@field}
          label={@param.name}
          step="1"
          min={@param.min}
          max={@param.max}
          placeholder={format_value(@param, @param.default)}
        />
      <% "number" -> %>
        <.input
          type="number"
          field={@field}
          label={@param.name}
          step="any"
          min={@param.min}
          max={@param.max}
          placeholder={format_value(@param, @param.default)}
        />
      <% "color" -> %>
        <.input type="color" field={@field} label={@param.name} />
      <% _text -> %>
        <.input
          type="text"
          field={@field}
          label={@param.name}
          placeholder={format_value(@param, @param.default)}
        />
    <% end %>
    """
  end

  defp page_title(%{doc: %{title: title}}) when is_binary(title), do: title
  defp page_title(%{path: path}), do: path

  defp source(%{path: path}) when is_binary(path), do: path <> " (local directory)"
  defp source(config), do: "#{RepoUrl.redact(config.repo)} @ #{config.ref}"

  defp defaults(catalog) do
    from_config = for {k, v} <- Enum.sort(catalog.config.params), do: {k, v, "configuration"}
    from_manifest = for {k, v} <- Enum.sort(catalog.current.screen.params), do: {k, v, "manifest"}
    from_config ++ from_manifest
  end

  defp type_text(%{type: "enum", values: values}), do: "enum: " <> Enum.join(values, ", ")

  defp type_text(%{type: type, min: min, max: max} = param) do
    limits =
      [min && "≥ #{format_value(param, min)}", max && "≤ #{format_value(param, max)}"]
      |> Enum.reject(&is_nil/1)

    from = if param.from, do: ["from #{param.from}"], else: []
    Enum.join([type | limits ++ from], ", ")
  end

  defp format_value(_param, nil), do: ""

  defp format_value(%{type: "duration"}, ms) when is_integer(ms),
    do: PageParams.format_duration(ms)

  defp format_value(_param, value), do: to_string(value)

  defp bytes(size), do: ByteSize.format(size)
end
