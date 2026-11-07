defmodule Deepsplay.PageDoc.Param do
  @moduledoc """
  One parameter definition of a page or helper (ADR 14), and the rules for
  turning a URL value into a typed value.

  These rules are the same as in the page helper `deepsplay.js`; both are
  tested against `test/support/fixtures/params_cases.json`.
  """

  alias Deepsplay.Duration

  @types ~w(string int number bool duration color enum)

  @enforce_keys [:name, :type]
  defstruct [:name, :type, :default, :min, :max, :description, :from, values: []]

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          default: term(),
          min: number() | nil,
          max: number() | nil,
          description: String.t() | nil,
          from: String.t() | nil,
          values: [String.t()]
        }

  @doc "The parameter types."
  def types, do: @types

  @doc """
  Builds a parameter from its TOML table. Returns the parameter and warnings
  for parts that were ignored, or only warnings if it is unusable.
  """
  @spec from_table(String.t(), term()) :: {t() | nil, [String.t()]}
  def from_table(name, table) when is_map(table) do
    ctx = ~s(parameter "#{name}")
    type = table["type"]

    cond do
      type not in @types ->
        {nil, ["#{ctx}: unknown type #{inspect(type)}"]}

      type == "enum" and not string_list?(table["values"]) ->
        {nil, ["#{ctx}: enum needs a list of values"]}

      true ->
        param = %__MODULE__{
          name: name,
          type: type,
          values: if(type == "enum", do: table["values"], else: [])
        }

        {min, w1} = limit(param, table["min"], "min", ctx)
        {max, w2} = limit(param, table["max"], "max", ctx)
        param = %{param | min: min, max: max}
        {default, w3} = default(param, table["default"], ctx)
        {description, w4} = optional_string(table["description"], "description", ctx)
        {from, w5} = from(table["from"], ctx)

        unknown =
          for key <- Map.keys(table) -- ~w(type values min max default description from),
              do: ~s(#{ctx}: unknown key "#{key}")

        {%{param | default: default, description: description, from: from},
         w1 ++ w2 ++ w3 ++ w4 ++ w5 ++ Enum.sort(unknown)}
    end
  end

  def from_table(name, _table), do: {nil, [~s(parameter "#{name}" must be a table)]}

  @doc """
  Converts a URL value to the parameter's type, applying its limits. Returns
  `:error` if the value is not valid for the type.
  """
  @spec cast(t(), String.t()) :: {:ok, term()} | :error
  def cast(%__MODULE__{type: "string"}, raw), do: {:ok, raw}

  def cast(%__MODULE__{type: "int"} = p, raw) do
    if Regex.match?(~r/^-?\d+$/, raw), do: {:ok, clamp(String.to_integer(raw), p)}, else: :error
  end

  def cast(%__MODULE__{type: "number"} = p, raw) do
    if Regex.match?(~r/^-?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$/, raw) do
      {:ok, clamp(to_number(raw), p)}
    else
      :error
    end
  end

  def cast(%__MODULE__{type: "bool"}, raw) do
    case String.downcase(raw) do
      v when v in ["true", "1", "yes", "on", ""] -> {:ok, true}
      v when v in ["false", "0", "no", "off"] -> {:ok, false}
      _other -> :error
    end
  end

  def cast(%__MODULE__{type: "duration"} = p, raw) do
    case Duration.parse(raw) do
      {:ok, ms} -> {:ok, clamp(ms, p)}
      :error -> :error
    end
  end

  def cast(%__MODULE__{type: "color"}, raw) do
    cond do
      match = Regex.run(~r/^#?([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/, raw) ->
        {:ok, "#" <> String.downcase(Enum.at(match, 1))}

      Regex.match?(~r/^[a-zA-Z]+$/, raw) ->
        {:ok, String.downcase(raw)}

      true ->
        :error
    end
  end

  def cast(%__MODULE__{type: "enum", values: values}, raw) do
    if raw in values, do: {:ok, raw}, else: :error
  end

  @doc """
  Reads parameters from a query string: each defined parameter gets its URL
  value if valid, else its default; parameters with neither are left out.
  """
  @spec values(%{String.t() => t()}, String.t()) :: %{String.t() => term()}
  def values(params, query) do
    # Like URLSearchParams.get: the first value of a repeated key counts.
    given =
      query
      |> String.trim_leading("?")
      |> URI.query_decoder()
      |> Enum.reverse()
      |> Map.new()

    # Not a comprehension filter: `false` is a value, not a missing one.
    Enum.reduce(params, %{}, fn {name, param}, acc ->
      case value(param, Map.fetch(given, name)) do
        nil -> acc
        value -> Map.put(acc, name, value)
      end
    end)
  end

  defp value(param, {:ok, raw}) do
    case cast(param, raw) do
      {:ok, value} -> value
      :error -> param.default
    end
  end

  defp value(param, :error), do: param.default

  defp clamp(value, %__MODULE__{min: min, max: max}) do
    cond do
      min != nil and value < min -> min
      max != nil and value > max -> max
      true -> value
    end
  end

  # Integers stay integers, as in JavaScript's Number they are the same.
  defp to_number(raw) do
    case Integer.parse(raw) do
      {int, ""} -> int
      _other -> raw |> normalize_float() |> String.to_float()
    end
  end

  defp normalize_float(raw) do
    raw =
      cond do
        String.starts_with?(raw, ".") -> "0" <> raw
        String.starts_with?(raw, "-.") -> "-0" <> String.trim_leading(raw, "-")
        true -> raw
      end

    raw = String.replace(raw, ~r/\.(?=[eE]|$)/, ".0")
    if String.contains?(raw, "."), do: raw, else: String.replace(raw, ~r/[eE]/, ".0e")
  end

  defp limit(_param, nil, _key, _ctx), do: {nil, []}

  defp limit(%__MODULE__{type: "duration"}, value, key, ctx) when is_binary(value) do
    case Duration.parse(value) do
      {:ok, ms} -> {ms, []}
      :error -> {nil, ["#{ctx}: invalid #{key}, ignored"]}
    end
  end

  defp limit(%__MODULE__{type: type}, value, _key, _ctx)
       when type in ~w(int number duration) and is_number(value),
       do: {value, []}

  defp limit(_param, _value, key, ctx), do: {nil, ["#{ctx}: invalid #{key}, ignored"]}

  # A default is converted like a URL value would be.
  defp default(_param, nil, _ctx), do: {nil, []}

  defp default(param, value, ctx) do
    text =
      cond do
        is_boolean(value) -> to_string(value)
        is_integer(value) -> Integer.to_string(value)
        is_float(value) -> js_float(value)
        is_binary(value) -> value
        true -> nil
      end

    case text && cast(param, text) do
      {:ok, value} -> {value, []}
      _invalid -> {nil, ["#{ctx}: invalid default, ignored"]}
    end
  end

  # JavaScript writes 10.0 as "10"; keep the same text so an int-like float
  # default is valid for int parameters in both.
  defp js_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15,
      do: value |> trunc() |> Integer.to_string(),
      else: Float.to_string(value)
  end

  defp optional_string(nil, _key, _ctx), do: {nil, []}
  defp optional_string(value, _key, _ctx) when is_binary(value), do: {value, []}
  defp optional_string(_value, key, ctx), do: {nil, ["#{ctx}: #{key} must be a string"]}

  defp from(nil, _ctx), do: {nil, []}
  defp from("duration", _ctx), do: {"duration", []}
  defp from(value, ctx), do: {nil, ["#{ctx}: unknown from #{inspect(value)}"]}

  defp string_list?(list), do: is_list(list) and list != [] and Enum.all?(list, &is_binary/1)
end
