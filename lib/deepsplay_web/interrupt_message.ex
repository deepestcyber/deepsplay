defmodule DeepsplayWeb.InterruptMessage do
  @moduledoc """
  Turns an MQTT message into interrupt triggers (ADR 33), without any
  connection: the connection (`DeepsplayWeb.Mqtt`) hands each message to
  `dispatch/3`.

  The last level of the topic is the name of the interrupt. Every
  configuration whose `mqtt_topic` matches the topic gets the trigger, as
  `DeepsplayWeb.Interrupts.start/4` with source `:mqtt`. The payload is
  empty or a flat JSON object of page parameters (`params/1`).

  Retained messages are dropped: the broker sends them on every subscribe,
  which would start an old interrupt again after each reconnect.
  """

  require Logger

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Screen
  alias DeepsplayWeb.Interrupts

  @max_payload 2048

  @doc """
  Matches a topic against a topic filter whose levels are names or `+`, as
  `mqtt_topic` allows (no `#`). Returns the last level of the topic, the name
  of the interrupt, or `:nomatch`. Topics starting with `$` never match
  (MQTT 3.1.1, 4.7.2).

      iex> DeepsplayWeb.InterruptMessage.match("deepcyber/+/interrupts/+", "deepcyber/lobby/interrupts/doorbell")
      {:ok, "doorbell"}

      iex> DeepsplayWeb.InterruptMessage.match("deepcyber/lobby/interrupts/+", "deepcyber/lobby/doorbell")
      :nomatch
  """
  @spec match(String.t(), String.t()) :: {:ok, String.t()} | :nomatch
  def match(_filter, "$" <> _topic), do: :nomatch

  def match(filter, topic) do
    filter_levels = String.split(filter, "/")
    topic_levels = String.split(topic, "/")

    matches =
      length(filter_levels) == length(topic_levels) and
        Enum.all?(Enum.zip(filter_levels, topic_levels), fn
          {"+", _level} -> true
          {level, level} -> true
          _different -> false
        end)

    if matches, do: {:ok, List.last(topic_levels)}, else: :nomatch
  end

  @doc """
  Reads the page parameters from a payload: empty gives none; otherwise a
  JSON object of at most 2 KB. Strings are taken as they are, numbers and
  booleans as their text, `null` as not given. Nested objects and arrays
  are rejected. Pairs are sorted by name, as JSON objects have no order.

      iex> DeepsplayWeb.InterruptMessage.params(~s({"who": "Ada", "level": 2, "loud": true, "gone": null}))
      {:ok, [{"level", "2"}, {"loud", "true"}, {"who", "Ada"}]}

      iex> DeepsplayWeb.InterruptMessage.params("")
      {:ok, []}

      iex> DeepsplayWeb.InterruptMessage.params("who=Ada")
      {:error, {:invalid, ["the payload is not JSON"]}}
  """
  @spec params(binary()) :: Interrupts.params()
  def params(""), do: {:ok, []}

  def params(payload) when byte_size(payload) > @max_payload,
    do: {:error, {:invalid, ["the payload is larger than #{div(@max_payload, 1024)} KB"]}}

  def params(payload) do
    case Jason.decode(payload) do
      {:ok, object} when is_map(object) ->
        {pairs, reasons} =
          object
          |> Enum.sort()
          |> Enum.flat_map_reduce([], fn {name, value}, reasons ->
            case text(value) do
              {:ok, nil} -> {[], reasons}
              {:ok, text} -> {[{name, text}], reasons}
              :error -> {[], reasons ++ [~s("#{name}" must be a string, number or boolean)]}
            end
          end)

        if reasons == [], do: {:ok, pairs}, else: {:error, {:invalid, reasons}}

      {:ok, _not_an_object} ->
        {:error, {:invalid, ["the payload is not a JSON object"]}}

      {:error, _error} ->
        {:error, {:invalid, ["the payload is not JSON"]}}
    end
  end

  defp text(nil), do: {:ok, nil}
  defp text(value) when is_binary(value), do: {:ok, value}
  defp text(value) when is_boolean(value), do: {:ok, Atom.to_string(value)}
  defp text(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp text(value) when is_float(value), do: {:ok, Float.to_string(value)}
  defp text(_list_or_map), do: :error

  @doc """
  Handles one message: triggers the interrupt in every configuration whose
  `mqtt_topic` matches, logs the outcome and returns it per configuration
  (`[]` when nothing matched or the message was dropped).
  """
  @spec dispatch(String.t(), binary(), boolean()) :: [{String.t(), Interrupts.answer()}]
  def dispatch(topic, _payload, true = _retain) do
    Logger.debug("MQTT: retained message on #{topic} ignored")
    []
  end

  def dispatch(topic, payload, false) do
    case matching(topic) do
      [] ->
        []

      [{_config, name} | _more] = matches ->
        case Screen.cast_interrupt_name(name) do
          {:ok, _name} ->
            params = params(payload)
            for {config, name} <- matches, do: trigger(config, name, params, topic)

          {:error, _why} ->
            Logger.warning(~s(MQTT: "#{name}" on #{topic} is not an interrupt name, ignored))
            []
        end
    end
  end

  defp matching(topic) do
    case Store.get() do
      {:ok, host_config} ->
        for {_name, %Config{mqtt_topic: filter} = config} <- Enum.sort(host_config.configs),
            filter != nil,
            {:ok, name} <- [match(filter, topic)],
            do: {config, name}

      {:error, _errors} ->
        []
    end
  end

  defp trigger(config, name, params, topic) do
    answer = Interrupts.start(config, name, params, :mqtt)
    log(config.name, name, topic, answer)
    {config.name, answer}
  end

  defp log(config, name, topic, answer) do
    what = ~s(MQTT: interrupt "#{name}" of #{config} from #{topic})

    case answer do
      {:ok, %{screens: screens}} ->
        Logger.info("#{what} started on #{screens} screen(s)")

      {:error, :not_found} ->
        Logger.warning("#{what}: no such interrupt, or no revision yet")

      {:error, :too_many} ->
        Logger.info("#{what} ignored, started within 2 seconds")

      {:error, {:invalid, reasons}} ->
        Logger.warning("#{what}: invalid parameters: #{Enum.join(reasons, "; ")}")
    end
  end
end
