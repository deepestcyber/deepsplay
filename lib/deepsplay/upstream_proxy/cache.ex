defmodule Deepsplay.UpstreamProxy.Cache do
  @moduledoc """
  Short-lived cache of upstream answers (ADR 8), so many screens share one
  upstream call within an upstream's `cache_ttl`. Expired entries are swept
  once a minute.
  """

  use GenServer

  @table __MODULE__
  @sweep 60_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Returns a fresh cached answer, or `:miss`.
  """
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires}] when expires > now -> {:ok, value}
      _other -> :miss
    end
  end

  @doc """
  Caches an answer for `ttl` milliseconds.
  """
  @spec put(term(), term(), pos_integer()) :: true
  def put(key, value, ttl) do
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl})
  end

  @doc false
  # Forgets everything; for tests.
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, state}
  end
end
