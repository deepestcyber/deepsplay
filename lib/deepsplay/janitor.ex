defmodule Deepsplay.Janitor do
  @moduledoc """
  Deletes cache directories of repositories no configuration refers to any
  more, at start and once a day (ADR 6).
  """

  use GenServer

  require Logger

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RevisionStore

  @interval 24 * 60 * 60_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if Application.get_env(:deepsplay, :start_pollers, true),
      do: {:ok, nil, {:continue, :clean}},
      else: :ignore
  end

  @impl true
  def handle_continue(:clean, state), do: {:noreply, clean(state)}

  @impl true
  def handle_info(:clean, state), do: {:noreply, clean(state)}

  defp clean(state) do
    with {:ok, host_config} <- Store.get() do
      repos = host_config.configs |> Map.values() |> Enum.map(& &1.repo) |> Enum.uniq()

      case RevisionStore.prune_repositories(repos) do
        :ok -> :ok
        {:error, error} -> Logger.warning("cleaning the cache: #{inspect(error)}")
      end
    end

    Process.send_after(self(), :clean, @interval)
    state
  end
end
