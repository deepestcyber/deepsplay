defmodule DeepsplayWeb.ShellLive do
  @moduledoc """
  The screen shell: what a kiosk screen opens on `/` or `/c/<name>`.

  With a revision, the shell sends the plan to the browser, where a hook
  rotates the pages in iframes (ADR 9). `?page=<path>` pins the screen to one
  file of `pages/` (ADR 11). New revisions arrive over PubSub and replace the
  plan; the browser applies it at the next page change.

  Without a revision to show, the shell is the fallback page. It says which
  configuration the screen asked for and what is missing.

  When the host configuration changes (ADR 23) and this screen's
  configuration is affected (changed, removed, or available again), the shell
  reloads itself.

  Connected shells are tracked with `DeepsplayWeb.Presence` for the status
  page: configuration, state, revision and current page, whether pinned,
  plus the optional `?screen=<label>` naming a kiosk.

  Interrupts (ADR 32) arrive over PubSub and are pushed to the hook as
  `interrupt` and `interrupt_end` events, unless the screen is pinned or has
  no revision to show. Nothing is pushed on mount: an interrupt reaches only
  the screens connected when it is triggered.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.HostConfig.Watcher
  alias Deepsplay.RepoUrl
  alias Deepsplay.RevisionFile
  alias Deepsplay.PageParams
  alias Deepsplay.Revisions
  alias Deepsplay.Screen
  alias Deepsplay.Status
  alias DeepsplayWeb.Interrupts
  alias DeepsplayWeb.Presence
  alias DeepsplayWeb.ScreenPlan
  alias DeepsplayWeb.TrustedProxies

  @impl true
  def mount(params, _session, socket) do
    requested = Map.get(params, "name", :default)
    if connected?(socket), do: Watcher.subscribe()

    socket = assign(socket, screen_settings())

    socket =
      case Store.lookup(requested) do
        {:ok, config} ->
          if connected?(socket) do
            Revisions.subscribe(config.name)
            Interrupts.subscribe(config.name)
          end

          socket
          |> assign(config: config, pinned: params["page"], status: Status.get(config.name))
          |> load_revision()

        {:error, :unknown_config} ->
          assign(socket, state: :unknown_config, name: requested, page_title: "Unknown")

        {:error, {:host_config, errors}} ->
          assign(socket, state: :host_config, errors: errors, page_title: "Error")
      end

    socket =
      assign(socket,
        requested: requested,
        lookup: Store.lookup(requested),
        # After a deployment, a screen reconnecting with the old app.js and
        # app.css loads the page again to get the new ones (ADR 30): the plan
        # it receives may be in a newer form.
        static_changed: connected?(socket) and static_changed?(socket)
      )

    {:ok, track(socket, requested, params["screen"])}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    path = if(query, do: path <> "?" <> query, else: path)

    if socket.assigns.static_changed,
      do: {:noreply, redirect(socket, to: path)},
      else: {:noreply, assign(socket, path: path)}
  end

  # Tracks the connected screen; updated when its state or page changes.
  defp track(socket, requested, label) do
    if connected?(socket) do
      id = "screen-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))

      meta =
        Map.merge(presence_state(socket), %{
          config: if(requested == :default, do: default_name(socket), else: requested),
          label: label,
          pinned: socket.assigns[:pinned] != nil,
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

  # Kiosk mode (ADR 35) and the development overlay (ADR 36). Without a
  # usable host configuration, screens stay in kiosk mode, without overlay.
  defp screen_settings do
    case Store.get() do
      {:ok, host_config} ->
        [kiosk_mode: host_config.kiosk_mode, dev_overlay: host_config.dev_overlay]

      _error ->
        [kiosk_mode: true, dev_overlay: false]
    end
  end

  defp default_name(%{assigns: %{config: config}}), do: config.name
  defp default_name(_socket), do: nil

  # The screen's address, behind a trusted proxy from X-Forwarded-For
  # (ADR 34). The peer data comes from the connection, not from the request
  # that the endpoint rewrites.
  defp peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} ->
        forwarded_for =
          for {"x-forwarded-for", value} <- get_connect_info(socket, :x_headers) || [],
              do: value

        address
        |> TrustedProxies.client_ip(forwarded_for)
        |> :inet.ntoa()
        |> to_string()

      _other ->
        nil
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

  # A changed host configuration: reload if what this screen shows depends
  # on the change (a new revision is announced separately).
  def handle_info({:host_config_changed}, socket) do
    socket = assign(socket, screen_settings())

    if Store.lookup(socket.assigns.requested) == socket.assigns.lookup,
      do: {:noreply, socket},
      else: {:noreply, push_navigate(socket, to: socket.assigns.path)}
  end

  def handle_info({:interrupt, payload}, socket),
    do: {:noreply, push_interrupt(socket, "interrupt", payload)}

  def handle_info({:interrupt_end, payload}, socket),
    do: {:noreply, push_interrupt(socket, "interrupt_end", payload)}

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
       added: current.added,
       override_added: current.override_added,
       empty_added: current.empty_added
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

  # Pinned screens ignore interrupts; screens without a revision have no hook.
  defp push_interrupt(%{assigns: %{state: :playing, pinned: nil}} = socket, event, payload),
    do: push_event(socket, event, payload)

  defp push_interrupt(socket, _event, _payload), do: socket

  # The hook element is not re-rendered (phx-update="ignore"), so later plans
  # are pushed as events; the hook ignores a plan it already has.
  defp push_plan(socket, plan) do
    if connected?(socket), do: push_event(socket, "plan", plan), else: socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.screen kiosk_mode={@kiosk_mode}>
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
      <.dev_overlay :if={@dev_overlay} config={assigns[:config]} />
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
      // Time windows (ADR 25): at each page change, the next page is picked
      // among the pages active at that moment. With none active, the plan's
      // empty page is shown, or a black screen. Overrides interrupt the
      // rotation while their windows are active; afterwards it continues with
      // the interrupted page. The hook checks at every full minute, or every
      // full second while a window of the plan has seconds (ADR 30).
      //
      // A page can end its display time with Deepsplay.done() (ADR 31): the
      // shell accepts the message from the visible page once it has been fully
      // visible for MIN_SHOWN, and moves on. The same page is loaded again in
      // the other frame; an override ends on this screen until its window
      // closes.
      //
      // Interrupts (ADR 32) arrive as events from the server: {name, url,
      // priority, duration}. One replaces what an override or another
      // interrupt shows if its priority is equal or higher, and is shown for
      // its duration from its arrival, until done() or interrupt_end. An
      // override that opens meanwhile with equal or higher priority drops it.
      // Afterwards the screen shows what ADR 25 gives: the highest active
      // override, or the rotation with the interrupted page. Nothing about
      // interrupts survives a reload.
      //
      // Random rotation (ADR 37) leaves out the entries picked within the
      // last no_repeat_entries picks and the files picked within the last
      // no_repeat_pages picks, as far as something is left. What was picked
      // is remembered by entry and file across plans, not across reloads.
      //
      // Plan: {sha, mode: "sequential" | "random" | "pinned", apply,
      //        no_repeat_entries, no_repeat_pages,
      //        pages: [{url, entry, file, duration, weight, when}],
      //        overrides: [{url, when, priority, duration_params}], empty}
      import {
        acceptsInterrupt,
        active,
        activeIndices,
        activeOverrideKeys,
        currentOverride,
        dismiss,
        remainingMs,
        secondPrecise,
        msToNextCheck,
        overrideOpened,
        pickRandom,
        remember,
      } from "@/js/schedule"

      const LOAD_TIMEOUT = 10000
      const FADE = 500 // matches duration-500 on the frames
      const MIN_SHOWN = 2000 // before Deepsplay.done() takes effect

      export default {
        mounted() {
          this.frames = [this.createFrame(), this.createFrame()]
          this.active = 0
          this.index = -1
          this.mode = "rotation" // or "override", "interrupt", "empty"
          this.overrideIndex = -1
          this.resumeIndex = -1
          this.plan = null
          this.planKey = null
          this.pending = null
          this.recent = [] // random picks, newest first (ADR 37)
          this.dismissed = new Map()
          this.activeKeys = new Set() // overrides active at the last check
          this.interrupt = null // {name, url, priority, duration}
          this.interruptTimer = null
          this.interruptEndsAt = 0
          this.shownUrl = ""
          this.announced = null // what the dev overlay was told last (ADR 36)
          this.onAsk = () => this.announced && this.dispatchShown(this.announced)
          window.addEventListener("deepsplay:ask", this.onAsk)
          this.onSkip = () => this.skip()
          window.addEventListener("deepsplay:skip", this.onSkip)
          this.loading = false
          this.shownAt = 0
          this.doneTimer = null
          this.onMessage = event => this.message(event)
          window.addEventListener("message", this.onMessage)
          this.setPlan(JSON.parse(this.el.dataset.plan))
          this.handleEvent("plan", plan => this.setPlan(plan))
          this.handleEvent("interrupt", interrupt => this.startInterrupt(interrupt))
          this.handleEvent("interrupt_end", ({name}) => {
            if (this.interrupt && this.interrupt.name === name) this.endInterrupt()
          })
          this.tick()
        },

        destroyed() {
          clearTimeout(this.timer)
          clearTimeout(this.loadTimer)
          clearTimeout(this.clearTimer)
          clearTimeout(this.tickTimer)
          clearTimeout(this.doneTimer)
          clearTimeout(this.interruptTimer)
          window.removeEventListener("message", this.onMessage)
          window.removeEventListener("deepsplay:ask", this.onAsk)
          window.removeEventListener("deepsplay:skip", this.onSkip)
        },

        // Tells the development overlay (ADR 36) what the screen shows now:
        // {url, mode, name, limit, since}. `limit` is the display time in ms
        // from `since` (a page's duration, the rest of an override's window
        // or of an interrupt), or null. The overlay asks with deepsplay:ask
        // when it mounts later.
        announce() {
          let mode = this.mode
          let limit = null
          let name = null
          const now = new Date()
          if (this.mode === "rotation") {
            if (this.plan.mode === "pinned") mode = "pinned"
            else limit = this.plan.pages[this.index]?.duration ?? null
          } else if (this.mode === "override") {
            limit = remainingMs((this.plan.overrides || [])[this.overrideIndex]?.when, now)
          } else if (this.mode === "interrupt") {
            name = this.interrupt.name
            limit = Math.max(0, this.interruptEndsAt - now.getTime())
          }
          this.announced = {url: this.shownUrl, mode, name, limit, since: now.getTime()}
          this.dispatchShown(this.announced)
        },

        dispatchShown(detail) {
          window.dispatchEvent(new CustomEvent("deepsplay:shown", {detail}))
        },

        // Deepsplay.done() from a page (ADR 31). Only the visible page of our
        // own origin counts, not one being replaced; it takes effect once the
        // page has been fully visible for MIN_SHOWN.
        message(event) {
          if (event.origin !== location.origin || event.data?.deepsplay !== "done") return
          const frame = this.frames[this.active]
          if (event.source !== frame.contentWindow) return
          if (this.loading || !frame.classList.contains("opacity-100") || this.doneTimer) return
          const wait = Math.max(0, this.shownAt + MIN_SHOWN - performance.now())
          this.doneTimer = setTimeout(() => {
            this.doneTimer = null
            this.done()
          }, wait)
        },

        // The skip button of the development overlay (ADR 36): ends what is
        // shown at once, as Deepsplay.done() would, without waiting for
        // MIN_SHOWN. A pinned page has nothing to move on to.
        skip() {
          if (!this.plan || this.plan.mode === "pinned") return
          clearTimeout(this.doneTimer)
          this.doneTimer = null
          this.done()
        },

        // Moves on from a page that is done: the next page (the same one
        // again, loaded fresh), the end of an override on this screen, or the
        // empty page again.
        done() {
          if (this.loading) return
          if (this.mode === "interrupt") {
            this.endInterrupt()
          } else if (this.mode === "override") {
            const override = (this.plan.overrides || [])[this.overrideIndex]
            if (override) dismiss(this.dismissed, override, new Date())
            this.checkOverride()
          } else if (this.mode === "empty") {
            if (this.activeNow().length > 0) this.showNext()
            else if (this.plan.empty) this.display(this.plan.empty.url, () => {})
          } else {
            clearTimeout(this.timer)
            this.showNext(true)
          }
        },

        // Frames take no pointer input: the mouse always stays over the shell,
        // whose cursor: none then hides the pointer on every page. Without
        // kiosk mode, the screen layout gives the visible frame pointer input
        // (ADR 35).
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
          } else if (this.mode === "interrupt") {
            // Nothing of the rotation is visible: the new plan applies at
            // once, the interrupt goes on unless an override it brings
            // replaces it. The rotation starts over afterwards.
            this.plan = plan
            this.pending = null
            this.index = -1
            this.resumeIndex = -1
            this.checkOverride()
          } else if (plan.apply === "now") {
            this.plan = plan
            this.pending = null
            this.reload()
          } else {
            this.pending = plan
          }
        },

        restart() {
          clearTimeout(this.timer)
          this.dropInterrupt()
          this.index = -1
          this.mode = "rotation"
          this.overrideIndex = -1
          if (!this.checkOverride()) this.showNext()
        },

        // Shows the current state of the new plan again, with a fresh timer.
        reload() {
          clearTimeout(this.timer)
          if (this.checkOverride(true)) return
          const page = this.plan.pages[this.index]
          if (this.mode === "rotation" && page && active(page.when, new Date())) this.showPage(this.index)
          else this.showNext()
        },

        // Checks at every full minute (or second) whether an override starts
        // or ends, or whether a page became active while none was.
        tick() {
          this.tickTimer = setTimeout(() => {
            if (!this.checkOverride() && this.mode === "empty" && this.activeNow().length > 0) {
              this.showNext()
            }
            this.tick()
          }, msToNextCheck(new Date(), this.secondPrecise()) + 50)
        },

        secondPrecise() {
          return [this.plan, this.pending].some(
            plan => plan && [...plan.pages, ...(plan.overrides || [])].some(e => secondPrecise(e.when))
          )
        },

        activeNow() {
          return activeIndices(this.plan.pages, new Date())
        },

        // Starts, switches or ends an override. Returns true while one is
        // shown. `force` shows the current one again.
        checkOverride(force = false) {
          if (this.plan.mode === "pinned") return false
          const now = new Date()
          const overrides = this.plan.overrides || []
          const current = currentOverride(overrides, now, this.dismissed)
          const previous = this.activeKeys
          this.activeKeys = activeOverrideKeys(overrides, now, this.dismissed)

          // An interrupt stays unless an override opened since the last
          // check with equal or higher priority (ADR 32).
          if (this.mode === "interrupt") {
            if (!overrideOpened(overrides, now, this.dismissed, previous, this.interrupt.priority)) return true
            this.dropInterrupt()
            this.mode = "override"
            this.overrideIndex = current
            this.display(this.overrideUrl(overrides[current], now), () => {})
            return true
          }

          if (current >= 0) {
            if (force || this.mode !== "override" || current !== this.overrideIndex) {
              if (this.mode !== "override") this.resumeIndex = this.mode === "rotation" ? this.index : -1
              clearTimeout(this.timer)
              this.mode = "override"
              this.overrideIndex = current
              this.display(this.overrideUrl(overrides[current], now), () => {})
            }
            return true
          }

          if (this.mode === "override") this.resume(now)
          return false
        },

        // Continues the rotation with the interrupted page, with a fresh
        // display time.
        resume(now) {
          this.mode = "rotation"
          this.overrideIndex = -1
          const page = this.plan.pages[this.resumeIndex]
          if (page && active(page.when, now)) this.showPage(this.resumeIndex)
          else this.showNext()
        },

        // The priority of what an override or interrupt shows, or null.
        shownPriority() {
          if (this.mode === "interrupt") return this.interrupt.priority
          if (this.mode === "override") return (this.plan.overrides || [])[this.overrideIndex]?.priority ?? null
          return null
        },

        // An interrupt arrives (ADR 32): shown if nothing of equal or higher
        // priority is; the same one again starts fresh.
        startInterrupt(interrupt) {
          if (!this.plan || this.plan.mode === "pinned") return
          if (!acceptsInterrupt(interrupt.priority, this.shownPriority())) return
          const now = new Date()
          if (this.mode !== "override" && this.mode !== "interrupt") {
            this.resumeIndex = this.mode === "rotation" ? this.index : -1
          }
          // Nothing of the rotation stays visible: a waiting plan applies now,
          // so its overrides count, and the rotation starts over afterwards.
          if (this.pending) {
            this.plan = this.pending
            this.pending = null
            this.index = -1
            this.resumeIndex = -1
          }
          // Overrides active now do not replace it; only those opening later.
          this.activeKeys = activeOverrideKeys(this.plan.overrides || [], now, this.dismissed)
          clearTimeout(this.timer)
          this.dropInterrupt()
          this.mode = "interrupt"
          this.overrideIndex = -1
          this.interrupt = interrupt
          this.interruptTimer = setTimeout(() => this.endInterrupt(), interrupt.duration)
          this.interruptEndsAt = now.getTime() + interrupt.duration
          this.display(interrupt.url, () => {})
        },

        // The interrupt is over on this screen (its time, done(),
        // interrupt_end): the highest active override, or the rotation.
        endInterrupt() {
          if (this.mode !== "interrupt") return
          this.dropInterrupt()
          const now = new Date()
          const overrides = this.plan.overrides || []
          const current = currentOverride(overrides, now, this.dismissed)
          this.activeKeys = activeOverrideKeys(overrides, now, this.dismissed)
          if (current >= 0) {
            this.mode = "override"
            this.overrideIndex = current
            this.display(this.overrideUrl(overrides[current], now), () => {})
          } else {
            this.resume(now)
          }
        },

        dropInterrupt() {
          clearTimeout(this.interruptTimer)
          this.interruptTimer = null
          this.interrupt = null
        },

        // An override's URL, with the remaining time of its window for
        // parameters that ask for the display time.
        overrideUrl(override, now) {
          const remaining = remainingMs(override.when, now)
          if (remaining === null || override.duration_params.length === 0) return override.url
          const added = override.duration_params.map(name => `${encodeURIComponent(name)}=${remaining}ms`)
          return override.url + (override.url.includes("?") ? "&" : "?") + added.join("&")
        },

        // The next page among the active ones; with none, the empty page.
        // `force` loads the page again when it is the same one.
        showNext(force = false) {
          if (this.mode === "override" || this.mode === "interrupt") return
          if (this.pending) {
            this.plan = this.pending
            this.pending = null
            this.index = -1
            if (this.checkOverride()) return
          }

          const next = this.pick()
          if (next === null) return this.showEmpty()
          // A single active page stays on screen without reloading.
          if (!force && next === this.index && this.mode === "rotation") {
            this.schedule(this.plan.pages[next])
            return this.announce()
          }
          this.showPage(next)
        },

        showPage(index) {
          const page = this.plan.pages[index]
          this.mode = "rotation"
          this.display(page.url, () => {
            this.index = index
            this.schedule(page)
          })
        },

        showEmpty() {
          if (this.mode === "empty") return
          clearTimeout(this.timer)
          this.mode = "empty"
          this.index = -1
          if (this.plan.empty) this.display(this.plan.empty.url, () => {})
          else this.blank()
        },

        // A black screen: the visible frame fades out and stops.
        blank() {
          clearTimeout(this.loadTimer)
          clearTimeout(this.doneTimer)
          this.doneTimer = null
          this.loading = false
          const old = this.frames[this.active]
          old.classList.replace("opacity-100", "opacity-0")
          this.pushEvent("page", {url: ""})
          this.shownUrl = ""
          this.announce()
          clearTimeout(this.clearTimer)
          this.clearTimer = setTimeout(() => {
            old.onload = null
            old.src = "about:blank"
          }, FADE)
        },

        // Picks the next page index among the active pages: in order, or
        // weighted at random without recent repeats (ADR 37). null when no
        // page is active.
        pick() {
          const pages = this.plan.pages
          const candidates = this.plan.mode === "pinned" ? [0] : this.activeNow()
          if (candidates.length === 0) return null

          if (this.plan.mode !== "random") {
            for (let step = 1; step <= pages.length; step++) {
              const i = (this.index + step + pages.length) % pages.length
              if (candidates.includes(i)) return i
            }
            return candidates[0]
          }

          const {no_repeat_entries: entries, no_repeat_pages: files} = this.plan
          const next = pickRandom(pages, candidates, this.recent, entries, files)
          this.recent = remember(this.recent, pages[next], entries, files)
          return next
        },

        // Loads a URL into the hidden frame and crossfades once it has
        // loaded, or after LOAD_TIMEOUT at the latest; then calls `shown`.
        display(url, shown) {
          const frame = this.frames[1 - this.active]

          // The hidden frame may still be due to be cleared, or loading
          // another page; this load replaces both.
          clearTimeout(this.clearTimer)
          clearTimeout(this.loadTimer)
          clearTimeout(this.doneTimer)
          this.doneTimer = null
          this.loading = true

          let swapped = false
          const swap = () => {
            if (swapped) return
            swapped = true
            clearTimeout(this.loadTimer)
            frame.onload = null
            this.loading = false
            this.shownAt = performance.now() + FADE

            const old = this.frames[this.active]
            old.classList.replace("opacity-100", "opacity-0")
            frame.classList.replace("opacity-0", "opacity-100")
            this.active = 1 - this.active
            this.pushEvent("page", {url})

            // Stop the old page once it has faded out.
            this.clearTimer = setTimeout(() => {
              old.onload = null
              old.src = "about:blank"
            }, FADE)

            shown()
            this.shownUrl = url
            this.announce()
          }

          frame.onload = () => {
            // Ignore the load of an empty frame, which some browsers report.
            try {
              if (frame.contentWindow.location.href === "about:blank") return
            } catch (_error) {}
            swap()
          }
          this.loadTimer = setTimeout(swap, LOAD_TIMEOUT)
          frame.src = url
        },

        // Shows the page for its duration; a pinned one stays until a new
        // plan arrives.
        schedule(page) {
          clearTimeout(this.timer)
          if (this.plan.mode === "pinned") return
          this.timer = setTimeout(() => this.showNext(), page.duration)
        },
      }
    </script>
    """
  end

  attr :config, Deepsplay.HostConfig.Config, default: nil

  # The development overlay (ADR 36): bottom left, over the pages, put there
  # by the shell. The rotation tells it what is shown (deepsplay:shown); it
  # counts the display time up, links to the page, the catalog and the status
  # page, and skips the page (deepsplay:skip). Collapsed, only the clock and
  # the skip button stay.
  defp dev_overlay(assigns) do
    ~H"""
    <div
      id="dev-overlay"
      phx-hook=".DevOverlay"
      phx-update="ignore"
      class="fixed bottom-3 left-3 z-50 flex max-w-[calc(100vw-1.5rem)] cursor-auto items-center gap-3 rounded-lg bg-zinc-900/85 px-3 py-1.5 font-mono text-sm text-zinc-100 shadow-lg ring-1 ring-white/10 backdrop-blur select-none"
    >
      <button
        type="button"
        id="dev-overlay-toggle"
        class="cursor-pointer text-zinc-400 transition-colors hover:text-zinc-100"
        aria-label="Collapse the overlay"
        aria-expanded="true"
      >
        <.icon name="hero-chevron-left-mini" class="dev-overlay-collapse size-4" />
        <.icon name="hero-chevron-right-mini" class="dev-overlay-expand hidden size-4" />
      </button>
      <span id="dev-overlay-clock" class="tabular-nums" title="Display time of the page">–:––</span>
      <button
        type="button"
        id="dev-overlay-skip"
        class="cursor-pointer text-zinc-400 transition-colors hover:text-zinc-100 disabled:cursor-default disabled:opacity-30 disabled:hover:text-zinc-400"
        title="Skip: end this page now (S)"
        aria-label="Skip the page"
      >
        <.icon name="hero-forward-mini" class="size-4" />
      </button>
      <span id="dev-overlay-details" class="flex min-w-0 items-center gap-3">
        <span id="dev-overlay-mode" class="text-xs text-amber-300"></span>
        <a
          id="dev-overlay-page"
          class="truncate text-zinc-300 underline-offset-2 hover:text-white hover:underline"
          title="Open the page on its own"
        ></a>
        <span class="flex shrink-0 items-center gap-2 border-l border-white/15 pl-3 text-zinc-400">
          <a
            :if={@config}
            id="dev-overlay-catalog"
            href={~p"/catalog/#{@config.name}"}
            class="transition-colors hover:text-white"
          >
            catalog
          </a>
          <a
            id="dev-overlay-status"
            href={~p"/status"}
            class="transition-colors hover:text-white"
          >
            status
          </a>
        </span>
      </span>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DevOverlay">
      // Display time: counts up from when the page appeared, with the page's
      // limit if it has one ("0:12 / 0:30"). Collapsing is remembered per
      // browser.
      //
      // The S key skips, like the button, also while a page has the focus:
      // the overlay listens in each page of our own origin as it appears.
      // Keys with modifiers, keys typed into a field and keys a page has
      // handled itself (preventDefault) are left alone.
      const KEY = "deepsplay.devOverlay.collapsed"
      const SKIP_KEY = "s"

      // Not instanceof: elements of a page belong to the frame's window.
      const typing = target =>
        Boolean(target?.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target?.tagName))

      const clock = ms => {
        const s = Math.max(0, Math.floor(ms / 1000))
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        const ss = String(s % 60).padStart(2, "0")
        return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`
      }

      // /c/<name>/r/<sha>/<path> → <path>
      const pagePath = url => {
        const rest = url.split("/r/")[1]
        return rest ? rest.split("/").slice(1).join("/") : url
      }

      export default {
        mounted() {
          this.shown = null
          this.clockEl = this.el.querySelector("#dev-overlay-clock")
          this.modeEl = this.el.querySelector("#dev-overlay-mode")
          this.pageEl = this.el.querySelector("#dev-overlay-page")
          this.toggle = this.el.querySelector("#dev-overlay-toggle")
          this.toggle.addEventListener("click", () => this.setCollapsed(!this.collapsed))
          this.skipEl = this.el.querySelector("#dev-overlay-skip")
          this.skipEl.addEventListener("click", () => this.skip())
          this.onKey = event => {
            if (event.defaultPrevented || event.repeat || event.ctrlKey || event.altKey || event.metaKey) return
            if (event.key.toLowerCase() !== SKIP_KEY || typing(event.target)) return
            event.preventDefault()
            this.skip()
          }
          window.addEventListener("keydown", this.onKey)
          let collapsed = false
          try {
            collapsed = localStorage.getItem(KEY) === "1"
          } catch (_error) {}
          this.setCollapsed(collapsed, false)

          this.onShown = event => {
            this.shown = event.detail
            this.update()
            this.listenInPages()
          }
          window.addEventListener("deepsplay:shown", this.onShown)
          this.timer = setInterval(() => this.tick(), 250)
          window.dispatchEvent(new Event("deepsplay:ask"))
        },

        destroyed() {
          clearInterval(this.timer)
          window.removeEventListener("deepsplay:shown", this.onShown)
          window.removeEventListener("keydown", this.onKey)
          for (const frame of document.querySelectorAll("#screen-rotation iframe")) {
            try {
              frame.contentWindow.removeEventListener("keydown", this.onKey)
            } catch (_error) {}
          }
        },

        skip() {
          if (!this.skipEl.disabled) window.dispatchEvent(new Event("deepsplay:skip"))
        },

        // A page loaded into a frame gets a new window; adding the same
        // listener again to a window that has it changes nothing. Pages of
        // another origin cannot be reached.
        listenInPages() {
          for (const frame of document.querySelectorAll("#screen-rotation iframe")) {
            try {
              frame.contentWindow.addEventListener("keydown", this.onKey)
            } catch (_error) {}
          }
        },

        setCollapsed(collapsed, remember = true) {
          this.collapsed = collapsed
          this.el.querySelector("#dev-overlay-details").classList.toggle("hidden", collapsed)
          this.el.querySelector(".dev-overlay-collapse").classList.toggle("hidden", collapsed)
          this.el.querySelector(".dev-overlay-expand").classList.toggle("hidden", !collapsed)
          this.toggle.setAttribute("aria-expanded", String(!collapsed))
          this.toggle.setAttribute("aria-label", collapsed ? "Expand the overlay" : "Collapse the overlay")
          if (remember) {
            try {
              localStorage.setItem(KEY, collapsed ? "1" : "0")
            } catch (_error) {}
          }
        },

        update() {
          const {url, mode, name} = this.shown
          this.modeEl.textContent = mode === "interrupt" ? `interrupt ${name}` : mode === "rotation" ? "" : mode
          this.pageEl.textContent = url ? pagePath(url) : "nothing shown"
          if (url) this.pageEl.href = url
          else this.pageEl.removeAttribute("href")
          this.skipEl.disabled = mode === "pinned"
          this.tick()
        },

        tick() {
          if (!this.shown) return
          const {since, limit} = this.shown
          const elapsed = clock(Date.now() - since)
          this.clockEl.textContent = limit == null ? elapsed : `${elapsed} / ${clock(limit)}`
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
