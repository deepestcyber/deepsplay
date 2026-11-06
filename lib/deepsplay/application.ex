defmodule Deepsplay.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Deepsplay.HostConfig.Store.load()

    children = [
      DeepsplayWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:deepsplay, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Deepsplay.PubSub},
      {Registry, keys: :unique, name: Deepsplay.RevisionStore.Registry},
      {DynamicSupervisor, name: Deepsplay.RevisionStore.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Deepsplay.TaskSupervisor},
      # Fetches every configuration once at startup; periodic polling follows
      # in the poller (ADR 7).
      {Task, &Deepsplay.Revisions.refresh_all/0},
      # Start a worker by calling: Deepsplay.Worker.start_link(arg)
      # {Deepsplay.Worker, arg},
      # Start to serve requests, typically the last entry
      DeepsplayWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Deepsplay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DeepsplayWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
