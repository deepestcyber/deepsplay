defmodule Deepsplay.TomlSchema do
  @moduledoc """
  Reads fields from decoded TOML tables, shared by the host configuration and
  `screen.toml`.

  Problems are collected as messages like `server.cache_dir is missing`, so a
  whole file can be reported at once.
  """

  alias Deepsplay.Duration

  @typedoc """
  A field: TOML key, struct field, type and options. The only option is
  `:default`; without it, the key is required.

  A type is a built-in name or a function returning `{:ok, value}` or
  `{:error, why}`.
  """
  @type spec :: {String.t(), atom(), type(), keyword()}
  @type type ::
          :string
          | :duration
          | :non_neg_integer
          | :positive_number
          | :string_list
          | :relative_path
          | {:enum, [String.t()]}
          | (term() -> {:ok, term()} | {:error, String.t()})

  @doc """
  Reads `specs` from `table`, applying defaults and reporting missing, invalid
  and unknown keys. `ctx` prefixes the messages.
  """
  @spec fields(map(), String.t(), [spec()]) :: {%{atom() => term()}, [String.t()]}
  def fields(table, ctx, specs) do
    known = Enum.map(specs, fn {key, _field, _type, _opts} -> key end)

    {values, errors} =
      Enum.map_reduce(specs, [], fn {key, field, type, opts}, errors ->
        case Map.fetch(table, key) do
          {:ok, value} ->
            case cast(type, value) do
              {:ok, value} -> {{field, value}, errors}
              {:error, why} -> {{field, nil}, errors ++ ["#{ctx}.#{key} #{why}"]}
            end

          :error ->
            if Keyword.has_key?(opts, :default) do
              {{field, opts[:default]}, errors}
            else
              {{field, nil}, errors ++ ["#{ctx}.#{key} is missing"]}
            end
        end
      end)

    {Map.new(values), errors ++ unknown_keys(table, known, ctx)}
  end

  @doc """
  Reports keys of `table` that are not in `known`, so typos are not silently
  ignored.
  """
  @spec unknown_keys(map(), [String.t()], String.t()) :: [String.t()]
  def unknown_keys(table, known, ctx) do
    table
    |> Map.keys()
    |> Enum.reject(&(&1 in known))
    |> Enum.sort()
    |> Enum.map(&~s(#{ctx}: unknown key "#{&1}"))
  end

  @doc """
  Casts a value to a type, see `t:type/0`.
  """
  @spec cast(type(), term()) :: {:ok, term()} | {:error, String.t()}
  def cast(fun, value) when is_function(fun, 1), do: fun.(value)

  def cast(:string, value) when is_binary(value) and value != "", do: {:ok, value}
  def cast(:string, _value), do: {:error, "must be a non-empty string"}

  def cast(:duration, value) do
    case Duration.parse(value) do
      {:ok, ms} -> {:ok, ms}
      :error -> {:error, ~s(must be a duration such as "30s", "5m" or "1h")}
    end
  end

  def cast(:non_neg_integer, value) when is_integer(value) and value >= 0, do: {:ok, value}
  def cast(:non_neg_integer, _value), do: {:error, "must be a non-negative integer"}

  def cast(:positive_number, value) when is_number(value) and value > 0, do: {:ok, value / 1}
  def cast(:positive_number, _value), do: {:error, "must be a number greater than 0"}

  def cast(:string_list, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {:ok, value},
      else: {:error, "must be a list of strings"}
  end

  def cast(:string_list, _value), do: {:error, "must be a list of strings"}

  def cast(:relative_path, value) when is_binary(value) do
    cond do
      value == "" -> {:error, "must not be empty"}
      Path.type(value) != :relative -> {:error, "must be a relative path"}
      ".." in Path.split(value) -> {:error, ~s(must not contain "..")}
      true -> {:ok, value}
    end
  end

  def cast(:relative_path, _value), do: {:error, "must be a string"}

  def cast({:enum, allowed}, value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "must be one of: #{Enum.map_join(allowed, ", ", &inspect/1)}"}
  end
end
