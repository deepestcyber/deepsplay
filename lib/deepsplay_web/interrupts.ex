defmodule DeepsplayWeb.Interrupts do
  @moduledoc """
  Triggers interrupts (ADR 32): checks a trigger against the configuration's
  current manifest, builds the page URL, sends the event to the screens of
  the configuration and forgets it.

  Triggers come over HTTP (`DeepsplayWeb.InterruptController`) or MQTT
  (ADR 33); `start/4` takes the parameters already read from either, and the
  source for the record.

  Only the last answer for each interrupt is kept (for the status page) and
  when it was last started (for the rate limit, shared by both sources), in
  an ETS table owned by this process. A restart forgets both.

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

  @typedoc "Where a trigger came from."
  @type source :: :http | :mqtt

  @typedoc """
  The parameters of a trigger as name-value pairs, in the order given, or
  why they could not be read.
  """
  @type params :: {:ok, [{String.t(), String.t()}]} | {:error, {:invalid, [String.t()]}}

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Subscribes the caller to the interrupts of the configuration `name`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(name), do: Phoenix.PubSub.subscribe(@pubsub, topic(name))

  @doc """
  Starts the interrupt `name` of `config` on the screens connected now, with
  `params` (see `parse_query/1`). An unknown interrupt is reported before
  parameters that could not be read. `source` is kept in the record.
  """
  @spec start(Config.t(), String.t(), params(), source()) :: answer()
  def start(%Config{} = config, name, params, source) do
    with {:ok, current, interrupt} <- find(config, name),
         {:ok, given} <- params,
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
    |> record(config.name, name, :start, source)
  end

  @doc "Ends the interrupt `name` of `config` on the screens showing it."
  @spec stop(Config.t(), String.t()) :: answer()
  def stop(%Config{} = config, name) do
    with {:ok, _current, interrupt} <- find(config, name) do
      Phoenix.PubSub.broadcast(@pubsub, topic(config.name), {:interrupt_end, %{name: name}})
      {:ok, %{screens: screens(config.name), duration: interrupt.duration}}
    end
    |> record(config.name, name, :stop, :http)
  end

  @doc """
  The last answer for each interrupt of the configuration `name` since the
  start: `%{interrupt => %{at, action, source, status, screens, reasons}}`.
  `status` is the HTTP status of the answer, also for MQTT, where nobody
  gets it; `reasons` explains a `422`.
  """
  @spec last(String.t()) :: %{String.t() => map()}
  def last(name) do
    for {{:last, ^name, interrupt}, entry} <- :ets.tab2list(@table),
        into: %{},
        do: {interrupt, entry}
  end

  @doc """
  One line about a trigger from `last/1`, e.g.
  `"POST 2027-03-04 10:00:00 UTC, 202 to 2 screens"` or
  `"MQTT 2027-03-04 10:00:00 UTC, started on 2 screens"`. MQTT publishers
  get no answer, so the outcome is worded, with the reasons of invalid
  parameters.
  """
  @spec describe(map()) :: String.t()
  def describe(%{at: at, source: :mqtt} = entry) do
    outcome =
      case entry do
        %{status: 202, screens: screens} -> "started on #{count_screens(screens)}"
        %{status: 429} -> "ignored, started within 2 seconds"
        %{status: 422, reasons: reasons} -> "invalid parameters: " <> Enum.join(reasons, "; ")
      end

    "MQTT #{time(at)}, #{outcome}"
  end

  def describe(%{at: at, action: action, status: status, screens: screens}) do
    method = if action == :start, do: "POST", else: "DELETE"
    to = if screens, do: " to #{count_screens(screens)}", else: ""
    "#{method} #{time(at)}, #{status}#{to}"
  end

  defp time(at),
    do: at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  defp count_screens(1), do: "1 screen"
  defp count_screens(n), do: "#{n} screens"

  @doc "The path that triggers the interrupt `interrupt` of the configuration `name`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(name, interrupt), do: "/c/#{name}/interrupts/#{interrupt}"

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

  @doc """
  Reads the parameters of an HTTP trigger from its raw query string (or
  `nil`), for `start/4`: at most 2 KB, each name once.
  """
  @spec parse_query(String.t() | nil) :: params()
  def parse_query(nil), do: {:ok, []}
  def parse_query(""), do: {:ok, []}

  def parse_query(query) when byte_size(query) > @max_query,
    do: {:error, {:invalid, ["the query is larger than #{div(@max_query, 1024)} KB"]}}

  def parse_query(query) do
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

  defp record({:error, :not_found} = answer, _config_name, _name, _action, _source), do: answer

  defp record(answer, config_name, name, action, source) do
    {status, screens, reasons} =
      case answer do
        {:ok, %{screens: screens}} -> {202, screens, []}
        {:error, :too_many} -> {429, nil, []}
        {:error, {:invalid, reasons}} -> {422, nil, reasons}
      end

    entry = %{
      at: DateTime.utc_now(),
      action: action,
      source: source,
      status: status,
      screens: screens,
      reasons: reasons
    }

    :ets.insert(@table, {{:last, config_name, name}, entry})
    Deepsplay.Status.notify(config_name)
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
