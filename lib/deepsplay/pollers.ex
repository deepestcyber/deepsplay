defmodule Deepsplay.Pollers do
  @moduledoc """
  Starts one `Deepsplay.Poller` per repository and ref of the host
  configuration (ADR 7), shared by all configurations using them, and one
  `Deepsplay.LocalWatcher` per configuration with a local `path` (ADR 12).

  Nothing is started when the host configuration is unusable, or when the
  `:start_pollers` application setting is false (as in tests).
  """

  use Supervisor

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.LocalWatcher

  @doc false
  def start_link(_opts), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    children =
      case {Application.get_env(:deepsplay, :start_pollers, true), Store.get()} do
        {true, {:ok, host_config}} -> child_specs(host_config)
        _other -> []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the poller child specs for a host configuration: one per repository
  and ref.
  """
  @spec child_specs(HostConfig.t()) :: [Supervisor.child_spec()]
  def child_specs(%HostConfig{} = host_config) do
    {local, git} = host_config.configs |> Map.values() |> Enum.split_with(&Config.local?/1)

    watchers = local |> Enum.sort_by(& &1.name) |> Enum.map(&{LocalWatcher, &1})

    pollers =
      git
      |> Enum.group_by(&{&1.repo, &1.ref})
      |> Enum.sort()
      |> Enum.map(fn {{repo, ref}, configs} ->
        {Deepsplay.Poller,
         url: repo,
         ref: ref,
         configs: Enum.sort_by(configs, & &1.name),
         interval: host_config.poll_interval,
         keep: host_config.keep_revisions}
      end)

    watchers ++ pollers
  end
end
