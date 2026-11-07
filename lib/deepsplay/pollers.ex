defmodule Deepsplay.Pollers do
  @moduledoc """
  Starts one `Deepsplay.Poller` per repository and ref of the host
  configuration (ADR 7), shared by all configurations using them, and one
  `Deepsplay.LocalWatcher` per configuration with a local `path` (ADR 12).

  Nothing is started when the host configuration is unusable, or when the
  `:start_pollers` application setting is false (as in tests).

  When the host configuration changes (ADR 23), `reconcile/2` stops pollers
  and watchers no longer needed, starts new ones and restarts those whose
  settings changed; unchanged ones keep running.
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
  Brings the running pollers and watchers from the `old` host configuration
  in line with the `new` one. Either may be unusable (`{:error, _}`), meaning
  none. Returns the ids of stopped and started children.
  """
  @spec reconcile(Store.state(), Store.state()) :: %{stopped: [term()], started: [term()]}
  def reconcile(old, new, supervisor \\ __MODULE__) do
    if Application.get_env(:deepsplay, :start_pollers, true) do
      old_specs = specs_by_id(old)
      new_specs = specs_by_id(new)

      stopped =
        for {id, spec} <- old_specs, Map.get(new_specs, id) != spec do
          _ = Supervisor.terminate_child(supervisor, id)
          _ = Supervisor.delete_child(supervisor, id)
          id
        end

      started =
        for {id, spec} <- new_specs, Map.get(old_specs, id) != spec do
          {:ok, _pid} = Supervisor.start_child(supervisor, spec)
          id
        end

      %{stopped: Enum.sort(stopped), started: Enum.sort(started)}
    else
      %{stopped: [], started: []}
    end
  end

  defp specs_by_id({:ok, host_config}) do
    host_config
    |> child_specs()
    |> Enum.map(&Supervisor.child_spec(&1, []))
    |> Map.new(&{&1.id, &1})
  end

  defp specs_by_id(_unusable), do: %{}

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
