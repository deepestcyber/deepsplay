defmodule Deepsplay.Status do
  @moduledoc """
  The latest polling and fetch outcome per configuration, kept in memory for
  the fallback page and the status page.

  Changes are announced to the configuration's subscribers (see
  `Deepsplay.Revisions.subscribe/1`) as `{:status_changed, name}`.
  """

  use GenServer

  @table __MODULE__
  @pubsub Deepsplay.PubSub

  @type t :: %{
          checked_at: DateTime.t() | nil,
          error: String.t() | nil,
          error_at: DateTime.t() | nil,
          next_check_at: DateTime.t() | nil
        }

  @empty %{checked_at: nil, error: nil, error_at: nil, next_check_at: nil}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Returns the status of the configuration `name`.
  """
  @spec get(String.t()) :: t()
  def get(name) do
    case :ets.lookup(@table, name) do
      [{^name, status}] -> status
      [] -> @empty
    end
  end

  @doc """
  Merges `changes` into the status of the configuration `name` and announces
  the change.
  """
  @spec update(String.t(), map()) :: t()
  def update(name, changes) do
    status = Map.merge(get(name), changes)
    :ets.insert(@table, {name, status})
    Phoenix.PubSub.broadcast(@pubsub, Deepsplay.Revisions.topic(name), {:status_changed, name})
    status
  end

  @doc false
  # Forgets all statuses; for tests.
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
