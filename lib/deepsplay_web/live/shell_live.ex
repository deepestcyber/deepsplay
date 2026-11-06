defmodule DeepsplayWeb.ShellLive do
  @moduledoc """
  The screen shell: what a kiosk screen opens on `/` or `/c/<name>`.

  With a revision, the shell sends the plan to the browser, where a hook
  rotates the pages in iframes (ADR 9). `?page=<path>` pins the screen to one
  file of `pages/` (ADR 11). New revisions arrive over PubSub and replace the
  plan; the browser applies it at the next page change.

  Without a revision to show, the shell is the fallback page. It says which
  configuration the screen asked for and what is missing.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl
  alias Deepsplay.RevisionFile
  alias Deepsplay.Revisions
  alias Deepsplay.Screen
  alias DeepsplayWeb.ScreenPlan

  @impl true
  def mount(params, _session, socket) do
    requested = Map.get(params, "name", :default)

    socket =
      case Store.lookup(requested) do
        {:ok, config} ->
          if connected?(socket), do: Revisions.subscribe(config.name)

          socket
          |> assign(config: config, pinned: params["page"])
          |> load_revision()

        {:error, :unknown_config} ->
          assign(socket, state: :unknown_config, name: requested, page_title: "Unknown")

        {:error, {:host_config, errors}} ->
          assign(socket, state: :host_config, errors: errors, page_title: "Error")
      end

    {:ok, socket}
  end

  @impl true
  def handle_info({:revision_published, _name, _sha}, socket) do
    {:noreply, load_revision(socket)}
  end

  defp load_revision(%{assigns: %{config: config, pinned: pinned}} = socket) do
    case Revisions.current(config) do
      {:ok, current} ->
        title = current.screen.title || config.name

        case plan(config, current, pinned) do
          {:ok, plan} ->
            socket
            |> assign(state: :playing, plan: plan, page_title: title)
            |> push_plan(plan)

          {:error, :pinned_missing} ->
            assign(socket, state: :pinned_missing, page_title: title)
        end

      :none ->
        assign(socket, state: :no_revision, page_title: config.name)

      {:error, errors} ->
        assign(socket, state: :revision_error, errors: errors, page_title: config.name)
    end
  end

  defp plan(config, current, nil),
    do: {:ok, ScreenPlan.rotation(config.name, current.sha, current.screen)}

  defp plan(config, current, pinned) do
    {path, query} = Screen.split_query(pinned)

    with true <- Screen.valid_query?(query),
         {:ok, _file} <- RevisionFile.resolve(current.pages_dir, path) do
      {:ok, ScreenPlan.pinned(config.name, current.sha, path, query)}
    else
      _missing -> {:error, :pinned_missing}
    end
  end

  # The hook element is not re-rendered (phx-update="ignore"), so later plans
  # are pushed as events; the hook ignores a plan it already has.
  defp push_plan(socket, plan) do
    if connected?(socket), do: push_event(socket, "plan", plan), else: socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.screen>
      <%= case @state do %>
        <% :playing -> %>
          <.rotation plan={@plan} />
        <% :no_revision -> %>
          <.no_revision config={@config} />
        <% :pinned_missing -> %>
          <.pinned_missing config={@config} page={@pinned} />
        <% :revision_error -> %>
          <.revision_error config={@config} errors={@errors} />
        <% :unknown_config -> %>
          <.unknown_config name={@name} />
        <% :host_config -> %>
          <.host_config_error errors={@errors} />
      <% end %>
    </Layouts.screen>
    """
  end

  attr :plan, :map, required: true

  defp rotation(assigns) do
    ~H"""
    <div
      id="screen-rotation"
      phx-hook=".Rotation"
      phx-update="ignore"
      data-plan={Jason.encode!(@plan)}
      class="relative h-full w-full"
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Rotation">
      // Rotates the pages of a plan in two iframes (ADR 9): the visible one,
      // and a hidden one that loads the next page when it is due.
      //
      // Nothing is preloaded: a page starts running (scripts, animations,
      // videos) only when it is about to be shown. The old page stays fully
      // visible until the new one has loaded, then they crossfade, and the old
      // frame is cleared so it stops running.
      //
      // Plan: {sha, mode: "sequential" | "random" | "pinned", pages: [{url, duration, weight}]}
      const LOAD_TIMEOUT = 10000
      const FADE = 500 // matches duration-500 on the frames

      export default {
        mounted() {
          this.frames = [this.createFrame(), this.createFrame()]
          this.active = 0
          this.index = -1
          this.plan = null
          this.planKey = null
          this.pending = null
          this.setPlan(JSON.parse(this.el.dataset.plan))
          this.handleEvent("plan", plan => this.setPlan(plan))
        },

        destroyed() {
          clearTimeout(this.timer)
          clearTimeout(this.loadTimer)
          clearTimeout(this.clearTimer)
        },

        createFrame() {
          const frame = document.createElement("iframe")
          frame.className = "absolute inset-0 h-full w-full border-0 opacity-0 transition-opacity duration-500"
          frame.setAttribute("aria-hidden", "true")
          this.el.appendChild(frame)
          return frame
        },

        // A new rotation plan takes effect at the next page change. A pinned
        // page, or a switch from or to pinning, applies at once.
        setPlan(plan) {
          const key = JSON.stringify(plan)
          if (key === this.planKey) return
          this.planKey = key

          if (!this.plan || plan.mode === "pinned" || this.plan.mode === "pinned") {
            this.plan = plan
            this.pending = null
            this.restart()
          } else {
            this.pending = plan
          }
        },

        restart() {
          clearTimeout(this.timer)
          this.index = -1
          this.display(this.pick())
        },

        advance() {
          if (this.pending) {
            this.plan = this.pending
            this.pending = null
            this.index = -1
          }
          this.display(this.pick())
        },

        // Picks the next page index: in order, or weighted at random without
        // repeating the current page when there is more than one.
        pick() {
          const pages = this.plan.pages
          if (this.plan.mode !== "random") {
            return (this.index + 1) % pages.length
          }
          const candidates = pages.map((page, i) => i).filter(i => pages.length === 1 || i !== this.index)
          const total = candidates.reduce((sum, i) => sum + pages[i].weight, 0)
          let r = Math.random() * total
          for (const i of candidates) {
            r -= pages[i].weight
            if (r < 0) return i
          }
          return candidates[candidates.length - 1]
        },

        // Loads a page into the hidden frame and crossfades once it has
        // loaded, or after LOAD_TIMEOUT at the latest.
        display(index) {
          const page = this.plan.pages[index]
          const frame = this.frames[1 - this.active]

          // The hidden frame may still be due to be cleared, or loading
          // another page; this load replaces both.
          clearTimeout(this.clearTimer)
          clearTimeout(this.loadTimer)

          let done = false
          const swap = () => {
            if (done) return
            done = true
            clearTimeout(this.loadTimer)
            frame.onload = null

            const old = this.frames[this.active]
            old.classList.replace("opacity-100", "opacity-0")
            frame.classList.replace("opacity-0", "opacity-100")
            this.active = 1 - this.active
            this.index = index

            // Stop the old page once it has faded out.
            this.clearTimer = setTimeout(() => {
              old.onload = null
              old.src = "about:blank"
            }, FADE)

            this.schedule(page)
          }

          frame.onload = () => {
            // Ignore the load of an empty frame, which some browsers report.
            try {
              if (frame.contentWindow.location.href === "about:blank") return
            } catch (_error) {}
            swap()
          }
          this.loadTimer = setTimeout(swap, LOAD_TIMEOUT)
          frame.src = page.url
        },

        // Shows the page for its duration. A single page, or a pinned one,
        // stays until a new plan arrives.
        schedule(page) {
          if (this.plan.mode === "pinned" || this.plan.pages.length === 1) return
          this.timer = setTimeout(() => this.advance(), page.duration)
        },
      }
    </script>
    """
  end

  attr :config, Deepsplay.HostConfig.Config, required: true

  defp no_revision(assigns) do
    ~H"""
    <.fallback_frame id="fallback-no-revision" icon="hero-clock" title="Waiting for content">
      <p>No revision of this configuration is available yet.</p>
      <.config_details config={@config} />
    </.fallback_frame>
    """
  end

  attr :config, Deepsplay.HostConfig.Config, required: true
  attr :page, :string, required: true

  defp pinned_missing(assigns) do
    ~H"""
    <.fallback_frame
      id="fallback-pinned-missing"
      icon="hero-document-magnifying-glass"
      title="Page not found"
    >
      <p>
        <span id="fallback-page" class="font-mono text-zinc-100">{@page}</span>
        is not a file in <span class="font-mono">pages/</span>
        of the current revision.
      </p>
      <.config_details config={@config} />
    </.fallback_frame>
    """
  end

  attr :config, Deepsplay.HostConfig.Config, required: true
  attr :errors, :list, required: true

  defp revision_error(assigns) do
    ~H"""
    <.fallback_frame
      id="fallback-revision-error"
      icon="hero-exclamation-triangle"
      title="Revision unusable"
      tone={:error}
    >
      <p>The current revision cannot be shown with this configuration.</p>
      <.error_list errors={@errors} />
      <.config_details config={@config} />
    </.fallback_frame>
    """
  end

  attr :name, :string, required: true

  defp unknown_config(assigns) do
    ~H"""
    <.fallback_frame
      id="fallback-unknown-config"
      icon="hero-question-mark-circle"
      title="Unknown configuration"
    >
      <p>
        No configuration named <span class="font-mono text-zinc-100">{@name}</span>
        is defined on this server.
      </p>
    </.fallback_frame>
    """
  end

  attr :errors, :list, required: true

  defp host_config_error(assigns) do
    ~H"""
    <.fallback_frame
      id="fallback-host-config"
      icon="hero-exclamation-triangle"
      title="Host configuration error"
      tone={:error}
    >
      <p>The server cannot use its host configuration.</p>
      <.error_list errors={@errors} />
    </.fallback_frame>
    """
  end

  attr :errors, :list, required: true

  defp error_list(assigns) do
    ~H"""
    <ul id="fallback-errors" class="mt-8 space-y-2 text-left font-mono text-base">
      <li :for={error <- @errors} class="border-l-2 border-red-500/60 pl-4">{error}</li>
    </ul>
    """
  end

  attr :config, Deepsplay.HostConfig.Config, required: true

  defp config_details(assigns) do
    ~H"""
    <dl class="mt-8 grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-left text-lg">
      <dt class="text-zinc-500">Configuration</dt>
      <dd id="fallback-config">{@config.name}</dd>
      <dt class="text-zinc-500">Repository</dt>
      <dd id="fallback-repo" class="break-all font-mono text-base">
        {RepoUrl.redact(@config.repo)}
      </dd>
      <dt class="text-zinc-500">Ref</dt>
      <dd id="fallback-ref" class="font-mono text-base">{@config.ref}</dd>
    </dl>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :tone, :atom, default: :info, values: [:info, :error]
  slot :inner_block, required: true

  defp fallback_frame(assigns) do
    ~H"""
    <section id={@id} class="flex h-full items-center justify-center p-12">
      <div class="w-full max-w-3xl text-center">
        <.icon
          name={@icon}
          class={[
            "size-16",
            @tone == :info && "text-zinc-500",
            @tone == :error && "text-red-400"
          ]}
        />
        <h1 class="mt-6 text-4xl font-semibold tracking-tight">{@title}</h1>
        <div class="mt-4 text-xl text-zinc-400">
          {render_slot(@inner_block)}
        </div>
        <p class="mt-16 text-sm uppercase tracking-[0.3em] text-zinc-600">deepsplay</p>
      </div>
    </section>
    """
  end
end
