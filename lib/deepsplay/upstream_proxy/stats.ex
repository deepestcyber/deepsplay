defmodule Deepsplay.UpstreamProxy.Stats do
  @moduledoc """
  Counters per upstream for the status page (ADR 20): cache hits, misses and
  stale answers served, the last upstream call and the last error. Kept in
  memory since the start.

  Upstreams are grouped as `{:host, name}` for upstreams of the host
  configuration and `{:manifest, url}` for upstreams declared in manifests,
  which share their cache entries by target.
  """

  use GenServer

  @table __MODULE__

  @type group :: {:host, String.t()} | {:manifest, String.t()}

  @type t :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          stale: non_neg_integer(),
          last_fetch_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          last_error_at: DateTime.t() | nil
        }

  @empty %{hits: 0, misses: 0, stale: 0, last_fetch_at: nil, last_error: nil, last_error_at: nil}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Counts an answer: `:hit`, `:miss` or `:stale`."
  @spec count(group(), :hit | :miss | :stale) :: :ok
  def count(group, kind) do
    position = %{hit: 2, miss: 3, stale: 4} |> Map.fetch!(kind)
    :ets.update_counter(@table, group, {position, 1}, default(group))
    :ok
  end

  @doc "Records an upstream call."
  @spec fetched(group()) :: :ok
  def fetched(group) do
    :ets.insert_new(@table, default(group))
    :ets.update_element(@table, group, {5, DateTime.utc_now()})
    :ok
  end

  @doc "Records a failed upstream call."
  @spec failed(group(), String.t()) :: :ok
  def failed(group, message) do
    :ets.insert_new(@table, default(group))
    :ets.update_element(@table, group, [{6, message}, {7, DateTime.utc_now()}])
    :ok
  end

  @doc "The counters of a group."
  @spec get(group()) :: t()
  def get(group) do
    case :ets.lookup(@table, group) do
      [{^group, hits, misses, stale, fetch_at, error, error_at}] ->
        %{
          hits: hits,
          misses: misses,
          stale: stale,
          last_fetch_at: fetch_at,
          last_error: error,
          last_error_at: error_at
        }

      [] ->
        @empty
    end
  end

  @doc false
  # Forgets everything; for tests.
  def clear, do: :ets.delete_all_objects(@table)

  defp default(group), do: {group, 0, 0, 0, nil, nil, nil}

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
