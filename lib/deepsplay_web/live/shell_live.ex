defmodule DeepsplayWeb.ShellLive do
  @moduledoc """
  The screen shell: what a kiosk screen opens on `/` or `/c/<name>`.

  Without a revision to show, the shell is the fallback page (ADR 9). It says
  which configuration the screen asked for and what is missing.
  """

  use DeepsplayWeb, :live_view

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl

  @impl true
  def mount(params, _session, socket) do
    requested = Map.get(params, "name", :default)

    socket =
      case Store.lookup(requested) do
        {:ok, config} ->
          assign(socket, fallback: :no_revision, config: config, page_title: config.name)

        {:error, :unknown_config} ->
          assign(socket, fallback: :unknown_config, name: requested, page_title: "Unknown")

        {:error, {:host_config, errors}} ->
          assign(socket, fallback: :host_config, errors: errors, page_title: "Error")
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.screen>
      <%= case @fallback do %>
        <% :no_revision -> %>
          <.no_revision config={@config} />
        <% :unknown_config -> %>
          <.unknown_config name={@name} />
        <% :host_config -> %>
          <.host_config_error errors={@errors} />
      <% end %>
    </Layouts.screen>
    """
  end

  attr :config, Deepsplay.HostConfig.Config, required: true

  defp no_revision(assigns) do
    ~H"""
    <.fallback_frame id="fallback-no-revision" icon="hero-clock" title="Waiting for content">
      <p>No revision of this configuration is available yet.</p>
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
      <ul id="fallback-errors" class="mt-8 space-y-2 text-left font-mono text-base">
        <li :for={error <- @errors} class="border-l-2 border-red-500/60 pl-4">{error}</li>
      </ul>
    </.fallback_frame>
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
