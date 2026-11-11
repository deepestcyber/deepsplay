defmodule DeepsplayWeb.Interrupts do
  @moduledoc """
  Triggers interrupts (ADR 32): checks a trigger against the configuration's
  current manifest, builds the page URL, sends the event to the screens of
  the configuration and forgets it.

  Only the last answer for each interrupt is kept (for the status page) and
  when it was last started (for the rate limit), in an ETS table owned by
  this process. A restart forgets both.

  Screens subscribe with `subscribe/1` and receive
  `{:interrupt, %{name, url, priority, duration}}` or
  `{:interrupt_end, %{name}}`.
  """

  use GenServer

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.PageParams
  alias Deepsplay.Revisions
  alias Deepsplay.Screen.Interrupt
  alias DeepsplayWeb.Presence
  alias DeepsplayWeb.ScreenPlan

  @pubsub Deepsplay.PubSub
  @table __MODULE__
  @min_interval 2_000
  @max_query 2048

  @type answer ::
          {:ok, %{screens: non_neg_integer(), duration: pos_integer()}}
          | {:error, :not_found}
          | {:error, :too_many}
          | {:error, {:invalid, [String.t()]}}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Subscribes the caller to the interrupts of the configuration `name`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(name), do: Phoenix.PubSub.subscribe(@pubsub, topic(name))

  @doc """
  Starts the interrupt `name` of `config` on the screens connected now, with
  the parameters in `query` (the raw query string, or `nil`).
  """
  @spec start(Config.t(), String.t(), String.t() | nil) :: answer()
  def start(%Config{} = config, name, query) do
    with {:ok, current, interrupt} <- find(config, name),
         {:ok, given} <- parse_query(query),
         :ok <- check(config, current, interrupt, given),
         :ok <- claim(config.name, name) do
      url = url(config, current, interrupt, given)

      payload = %{
        name: name,
        url: url,
        priority: interrupt.priority,
        duration: interrupt.duration
      }

      Phoenix.PubSub.broadcast(@pubsub, topic(config.name), {:interrupt, payload})
      {:ok, %{screens: screens(config.name), duration: interrupt.duration}}
    end
    |> record(config.name, name, :start)
  end

  @doc "Ends the interrupt `name` of `config` on the screens showing it."
  @spec stop(Config.t(), String.t()) :: answer()
  def stop(%Config{} = config, name) do
    with {:ok, _current, interrupt} <- find(config, name) do
      Phoenix.PubSub.broadcast(@pubsub, topic(config.name), {:interrupt_end, %{name: name}})
      {:ok, %{screens: screens(config.name), duration: interrupt.duration}}
    end
    |> record(config.name, name, :stop)
  end

  @doc """
  The last answer for each interrupt of the configuration `name` since the
  start: `%{interrupt => %{at, action, status, screens}}`.
  """
  @spec last(String.t()) :: %{String.t() => map()}
  def last(name) do
    for {{:last, ^name, interrupt}, entry} <- :ets.tab2list(@table),
        into: %{},
        do: {interrupt, entry}
  end

  @doc """
  Screens of the configuration `name` that get interrupts: connected,
  showing a revision and not pinned.
  """
  @spec screens(String.t()) :: non_neg_integer()
  def screens(name) do
    for {_id, %{metas: metas}} <- Presence.list(Presence.topic()),
        %{config: ^name, state: :playing, pinned: false} <- metas,
        reduce: 0,
        do: (count -> count + 1)
  end

  @doc false
  # For tests: forgets triggers and rate limits.
  def clear, do: :ets.delete_all_objects(@table)

  defp topic(name), do: "interrupts:" <> name

  defp find(config, name) do
    with {:ok, current} <- Revisions.current(config),
         %Interrupt{} = interrupt <- Enum.find(current.screen.interrupts, &(&1.name == name)) do
      {:ok, current, interrupt}
    else
      _none -> {:error, :not_found}
    end
  end

  defp parse_query(nil), do: {:ok, []}
  defp parse_query(""), do: {:ok, []}

  defp parse_query(query) when byte_size(query) > @max_query,
    do: {:error, {:invalid, ["the query is larger than #{div(@max_query, 1024)} KB"]}}

  defp parse_query(query) do
    given = query |> URI.query_decoder() |> Enum.to_list()

    case given |> Enum.frequencies_by(&elem(&1, 0)) |> Enum.filter(fn {_, n} -> n > 1 end) do
      [] ->
        {:ok, given}

      twice ->
        {:error, {:invalid, for({name, _} <- twice, do: ~s("#{name}" is given more than once))}}
    end
  rescue
    _malformed -> {:error, {:invalid, ["the query is malformed"]}}
  end

  defp check(config, current, interrupt, given) do
    case PageParams.check(Revisions.param_context(config, current), interrupt.path, given) do
      :ok -> :ok
      {:error, reasons} -> {:error, {:invalid, reasons}}
    end
  end

  # The trigger's parameters take precedence over the manifest's query and
  # all levels of ADR 16; `from = "duration"` gets the interrupt's duration.
  defp url(config, current, interrupt, given) do
    names = for {name, _} <- given, do: name

    own =
      case interrupt.query do
        nil -> []
        query -> query |> URI.query_decoder() |> Enum.reject(fn {name, _} -> name in names end)
      end

    query = PageParams.merge_query(nil, own ++ given)

    {added, _warnings, _declared} =
      PageParams.for_page(
        Revisions.param_context(config, current),
        interrupt.path,
        query,
        interrupt.duration
      )

    ScreenPlan.page_url(
      config.name,
      current.sha,
      interrupt.path,
      PageParams.merge_query(query, added)
    )
  end

  # The rate limit: the same interrupt starts at most every 2 seconds.
  defp claim(config_name, name),
    do:
      GenServer.call(__MODULE__, {:claim, config_name, name, System.monotonic_time(:millisecond)})

  defp record({:error, :not_found} = answer, _config_name, _name, _action), do: answer

  defp record(answer, config_name, name, action) do
    {status, screens} =
      case answer do
        {:ok, %{screens: screens}} -> {202, screens}
        {:error, :too_many} -> {429, nil}
        {:error, {:invalid, _reasons}} -> {422, nil}
      end

    entry = %{at: DateTime.utc_now(), action: action, status: status, screens: screens}
    :ets.insert(@table, {{:last, config_name, name}, entry})
    answer
  end

  # Server

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:claim, config_name, name, now}, _from, state) do
    key = {:started, config_name, name}

    reply =
      case :ets.lookup(@table, key) do
        [{^key, at}] when now - at < @min_interval ->
          {:error, :too_many}

        _never_or_long_ago ->
          :ets.insert(@table, {key, now})
          :ok
      end

    {:reply, reply, state}
  end
end
