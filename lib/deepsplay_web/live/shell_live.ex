defmodule DeepsplayWeb.ShellLive do
  @moduledoc """
  The screen shell: what a kiosk screen opens on `/` or `/c/<name>`.

  With a revision, the shell sends the plan to the browser, where a hook
  rotates the pages in iframes (ADR 9). `?page=<path>` pins the screen to one
  file of `pages/` (ADR 11). New revisions arrive over PubSub and replace the
  plan; the browser applies it at the next page change.

  Without a revision to show, the shell is the fallback page. It says which
  configuration the screen asked for and what is missing.

  Connected shells are tracked with `DeepsplayWeb.Presence` for the status
  page: configuration, state, revision and current page, plus the optional
  `?screen=<label>` naming a kiosk.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl
  alias Deepsplay.RevisionFile
  alias Deepsplay.PageParams
  alias Deepsplay.Revisions
  alias Deepsplay.Screen
  alias Deepsplay.Status
  alias DeepsplayWeb.Presence
  alias DeepsplayWeb.ScreenPlan

  @impl true
  def mount(params, _session, socket) do
    requested = Map.get(params, "name", :default)

    socket =
      case Store.lookup(requested) do
        {:ok, config} ->
          if connected?(socket), do: Revisions.subscribe(config.name)

          socket
          |> assign(config: config, pinned: params["page"], status: Status.get(config.name))
          |> load_revision()

        {:error, :unknown_config} ->
          assign(socket, state: :unknown_config, name: requested, page_title: "Unknown")

        {:error, {:host_config, errors}} ->
          assign(socket, state: :host_config, errors: errors, page_title: "Error")
      end

    {:ok, track(socket, requested, params["screen"])}
  end

  # Tracks the connected screen; updated when its state or page changes.
  defp track(socket, requested, label) do
    if connected?(socket) do
      id = "screen-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))

      meta =
        Map.merge(presence_state(socket), %{
          config: if(requested == :default, do: default_name(socket), else: requested),
          label: label,
          page: nil,
          page_since: nil,
          connected_at: DateTime.utc_now(),
          ip: peer_ip(socket),
          user_agent: get_connect_info(socket, :user_agent)
        })

      {:ok, _ref} = Presence.track(self(), Presence.topic(), id, meta)
      assign(socket, presence_id: id)
    else
      assign(socket, presence_id: nil)
    end
  end

  defp update_presence(%{assigns: %{presence_id: id}} = socket, changes) when is_binary(id) do
    Presence.update(self(), Presence.topic(), id, &Map.merge(&1, changes))
    socket
  end

  defp update_presence(socket, _changes), do: socket

  defp presence_state(%{assigns: %{state: :playing, plan: plan}}),
    do: %{state: :playing, sha: plan.sha}

  defp presence_state(%{assigns: %{state: state}}), do: %{state: state, sha: nil}

  defp default_name(%{assigns: %{config: config}}), do: config.name
  defp default_name(_socket), do: nil

  defp peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _other -> nil
    end
  end

  @impl true
  def handle_event("page", %{"url" => url}, socket) do
    page =
      case String.split(url, "/r/", parts: 2) do
        [_prefix, rest] -> rest |> String.split("/", parts: 2) |> List.last()
        _other -> url
      end

    {:noreply, update_presence(socket, %{page: page, page_since: DateTime.utc_now()})}
  end

  @impl true
  def handle_info({:revision_published, _name, _sha}, socket) do
    socket = load_revision(socket)
    {:noreply, update_presence(socket, presence_state(socket))}
  end

  def handle_info({:status_changed, name}, socket) do
    {:noreply, assign(socket, status: Status.get(name))}
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

  defp plan(config, current, nil) do
    {:ok,
     ScreenPlan.rotation(config.name, current.sha, current.screen,
       local: current.local,
       added: current.added
     )}
  end

  defp plan(config, current, pinned) do
    {path, query} = Screen.split_query(pinned)

    with true <- Screen.valid_query?(query),
         {:ok, _file} <- RevisionFile.resolve(current.pages_dir, path) do
      # Pinned pages get the same added parameters, without a display time.
      {added, _warnings, _declared} =
        PageParams.for_page(Revisions.param_context(config, current), path, query, nil)

      query = PageParams.merge_query(query, added)
      {:ok, ScreenPlan.pinned(config.name, current.sha, path, query, local: current.local)}
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
          <.no_revision config={@config} status={@status} />
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

        // Frames take no pointer input: the mouse always stays over the shell,
        // whose cursor: none then hides the pointer on every page.
        createFrame() {
          const frame = document.createElement("iframe")
          frame.className =
            "pointer-events-none absolute inset-0 h-full w-full border-0 opacity-0 transition-opacity duration-500"
          frame.setAttribute("aria-hidden", "true")
          this.el.appendChild(frame)
          return frame
        },

        // A new rotation plan takes effect at the next page change. A pinned
        // page, or a switch from or to pinning, applies at once. A plan with
        // apply "now" (local directories) reloads the current page in place.
        setPlan(plan) {
          const key = JSON.stringify(plan)
          if (key === this.planKey) return
          this.planKey = key

          if (!this.plan || plan.mode === "pinned" || this.plan.mode === "pinned") {
            this.plan = plan
            this.pending = null
            this.restart()
          } else if (plan.apply === "now") {
            this.plan = plan
            this.pending = null
            this.reload()
          } else {
            this.pending = plan
          }
        },

        // Shows the current position of the new plan again, with a fresh timer.
        reload() {
          clearTimeout(this.timer)
          const index = this.index >= 0 && this.index < this.plan.pages.length ? this.index : this.pick()
          this.display(index)
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
            this.pushEvent("page", {url: page.url})

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
  attr :status, :map, required: true

  defp no_revision(assigns) do
    ~H"""
    <.fallback_frame id="fallback-no-revision" icon="hero-clock" title="Waiting for content">
      <p>No revision of this configuration is available yet.</p>
      <.config_details config={@config} />
      <div
        :if={@status.error}
        id="fallback-last-error"
        class="mt-8 border-l-2 border-red-500/60 pl-4 text-left font-mono text-base text-zinc-300"
      >
        <p class="text-sm text-zinc-500">Last error, {format_time(@status.error_at)}</p>
        <p>{@status.error}</p>
      </div>
      <p :if={@status.next_check_at} id="fallback-next-check" class="mt-4 text-base text-zinc-500">
        Next attempt at {format_time(@status.next_check_at)}
      </p>
    </.fallback_frame>
    """
  end

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = time),
    do:
      time
      |> DateTime.truncate(:second)
      |> DateTime.to_time()
      |> Time.to_iso8601()
      |> Kernel.<>(" UTC")

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
      <%= if @config.path do %>
        <dt class="text-zinc-500">Directory</dt>
        <dd id="fallback-path" class="break-all font-mono text-base">{@config.path}</dd>
      <% else %>
        <dt class="text-zinc-500">Repository</dt>
        <dd id="fallback-repo" class="break-all font-mono text-base">
          {RepoUrl.redact(@config.repo)}
        </dd>
        <dt class="text-zinc-500">Ref</dt>
        <dd id="fallback-ref" class="font-mono text-base">{@config.ref}</dd>
      <% end %>
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
