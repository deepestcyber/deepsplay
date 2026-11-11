defmodule Deepsplay.Status do
  @moduledoc """
  The latest polling and fetch outcome per configuration, and a short log of
  recent errors, kept in memory for the fallback page and the status page.

  Changes are announced as `{:status_changed, name}` to the configuration's
  subscribers (see `Deepsplay.Revisions.subscribe/1`) and to subscribers of
  all configurations (`subscribe_all/0`).
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
  @all_topic "status"
  @max_log 50

  @type log_entry :: %{at: DateTime.t(), config: String.t(), message: String.t()}

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
    previous = get(name)
    status = Map.merge(previous, changes)
    :ets.insert(@table, {name, status})

    # A new error goes to the log; the same error repeated by every poll does
    # not.
    if status.error && status.error != previous.error do
      log(name, status.error, status.error_at || DateTime.utc_now())
    end

    Phoenix.PubSub.broadcast(@pubsub, Deepsplay.Revisions.topic(name), {:status_changed, name})
    Phoenix.PubSub.broadcast(@pubsub, @all_topic, {:status_changed, name})
    status
  end

  @doc """
  Adds an error to the log without changing the configuration's status, for
  problems that do not affect its content, such as upstream failures.
  """
  @spec log_error(String.t(), String.t()) :: :ok
  def log_error(name, message) do
    log(name, message, DateTime.utc_now())
    Phoenix.PubSub.broadcast(@pubsub, @all_topic, {:status_changed, name})
    :ok
  end

  @doc """
  Announces that something shown about the configuration `name` changed
  without changing its status, such as a triggered interrupt (ADR 32).
  """
  @spec notify(String.t()) :: :ok
  def notify(name) do
    Phoenix.PubSub.broadcast(@pubsub, @all_topic, {:status_changed, name})
    :ok
  end

  @doc """
  Subscribes the caller to status changes of all configurations.
  """
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all, do: Phoenix.PubSub.subscribe(@pubsub, @all_topic)

  @doc """
  Returns the most recent errors, newest first.
  """
  @spec recent_errors() :: [log_entry()]
  def recent_errors do
    case :ets.lookup(@table, :log) do
      [{:log, entries}] -> entries
      [] -> []
    end
  end

  # Serialized through the process, so concurrent errors are all kept.
  defp log(name, message, at) do
    GenServer.cast(__MODULE__, {:log, %{at: at, config: name, message: message}})
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    :ets.insert(@table, {:log, Enum.take([entry | recent_errors()], @max_log)})
    {:noreply, state}
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
