defmodule Deepsplay.Duration do
  @moduledoc """
  Parses durations written in configuration files, such as `"30s"` or `"5m"`.
  """

  @units %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}

  @doc """
  Parses a duration string into milliseconds.

  Accepts a positive integer followed by one of `ms`, `s`, `m` or `h`.

      iex> Deepsplay.Duration.parse("30s")
      {:ok, 30_000}

      iex> Deepsplay.Duration.parse("0s")
      :error
  """
  @spec parse(term()) :: {:ok, pos_integer()} | :error
  def parse(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)$/, value) do
      [_, amount, unit] ->
        case String.to_integer(amount) * Map.fetch!(@units, unit) do
          0 -> :error
          ms -> {:ok, ms}
        end

      nil ->
        :error
    end
  end

  def parse(_value), do: :error
end
