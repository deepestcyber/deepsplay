defmodule Deepsplay.Poller do
  @moduledoc """
  Polls one repository and ref for new commits (ADR 7), for every
  configuration that uses them.

  - Checks with `Deepsplay.RemoteRef.resolve/3` every `poll_interval`, with
    about 20 % random jitter. The first check runs right after start.
  - When the SHA differs from the last one seen, every configuration refreshes
    (fetch, validate, publish, announce), and old revisions are pruned. A SHA is
    acted on once: a rejected one is not retried until the branch moves again.
  - Only branches are polled. A tag or full SHA is resolved once at start.
  - On errors, the delay doubles up to 5 minutes; a success resets it.
  """

  use GenServer, restart: :permanent

  require Logger

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.RemoteRef
  alias Deepsplay.Revisions
  alias Deepsplay.RevisionStore
  alias Deepsplay.Status

  @max_backoff 5 * 60_000
  @jitter 0.2

  @doc """
  Starts a poller.

  ## Options

    * `:url`, `:ref` - what to poll
    * `:configs` - the configurations using them
    * `:interval` - poll interval in milliseconds
    * `:keep` - previous revisions kept per repository when pruning
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, opts[:url], opts[:ref]}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Checks right away instead of waiting for the next interval. Returns when the
  check is done.
  """
  def check_now(poller), do: GenServer.call(poller, :check_now, :infinity)

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :url),
      ref: Keyword.fetch!(opts, :ref),
      configs: Keyword.fetch!(opts, :configs),
      interval: Keyword.fetch!(opts, :interval),
      keep: Keyword.fetch!(opts, :keep),
      last_sha: nil,
      failures: 0,
      timer: nil
    }

    {:ok, state, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, check(state)}

  @impl true
  def handle_info(:check, state), do: {:noreply, check(state)}

  @impl true
  def handle_call(:check_now, _from, state), do: {:reply, :ok, check(state)}

  defp check(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    now = DateTime.utc_now()

    case RemoteRef.resolve(state.url, state.ref) do
      {:ok, %{sha: sha, kind: kind}} when sha == state.last_sha ->
        # Nothing new. A previous check error is over; a rejected revision's
        # error stays until the branch moves.
        recovered = if state.failures > 0, do: %{error: nil, error_at: nil}, else: %{}
        state = schedule_if_branch(%{state | failures: 0}, kind)
        record(state, Map.put(recovered, :checked_at, now))
        state

      {:ok, %{sha: sha, kind: kind}} ->
        state = schedule_if_branch(refresh(%{state | last_sha: sha}), kind)
        record(state, %{checked_at: now})
        state

      {:error, message} ->
        Logger.warning("polling #{state.ref}: #{message}")
        state = schedule(%{state | failures: state.failures + 1})
        record(state, %{checked_at: now, error: "check failed: " <> message, error_at: now})
        state
    end
  end

  defp refresh(state) do
    results = Enum.map(state.configs, &Revisions.refresh/1)

    in_use =
      for config <- state.configs,
          {:ok, current} <- [Revisions.current(config)],
          do: current.sha

    RevisionStore.prune(state.url, Enum.uniq(in_use), keep: state.keep)

    # A failed fetch counts as an error for the backoff; a rejected revision
    # does not, since retrying it would not help.
    if Enum.any?(results, &match?({:error, {:fetch, _}}, &1)),
      do: %{state | failures: state.failures + 1, last_sha: nil},
      else: %{state | failures: 0}
  end

  # Tags and SHAs do not move; they are resolved once.
  defp schedule_if_branch(state, :branch), do: schedule(state)
  defp schedule_if_branch(state, _kind), do: %{state | timer: nil}

  defp schedule(state) do
    delay = delay(state.interval, state.failures)
    %{state | timer: Process.send_after(self(), :check, delay)}
  end

  @doc false
  # Interval with jitter; doubled per failure, capped at 5 minutes.
  def delay(interval, failures) do
    base = min(interval * Integer.pow(2, min(failures, 16)), max(@max_backoff, interval))
    round(base * (1 - @jitter + :rand.uniform() * 2 * @jitter))
  end

  defp record(state, changes) do
    next =
      case state.timer do
        nil ->
          nil

        timer ->
          case Process.read_timer(timer) do
            false -> nil
            ms -> DateTime.add(DateTime.utc_now(), ms, :millisecond)
          end
      end

    for %Config{name: name} <- state.configs do
      Status.update(name, Map.put(changes, :next_check_at, next))
    end
  end
end
