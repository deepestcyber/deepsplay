defmodule Deepsplay.ByteSize do
  @moduledoc """
  Byte sizes as written in configurations and shown on pages.

  SI units count in powers of 1000 (`kB`, also `KB`; `MB`; `GB`), binary
  units in powers of 1024 (`KiB`, `MiB`, `GiB`); `B` and plain numbers are
  bytes. Decimals are rounded down to whole bytes. Units are matched as
  written, so `mb` or `Mb` (which reads as megabit) are refused.
  """

  @units %{
    "B" => 1,
    "kB" => 1_000,
    "KB" => 1_000,
    "MB" => 1_000_000,
    "GB" => 1_000_000_000,
    "KiB" => 1024,
    "MiB" => 1024 ** 2,
    "GiB" => 1024 ** 3
  }

  @doc """
  Parses a size: an integer number of bytes, or a string with an optional
  unit. The result must be at least 1 byte.

      iex> Deepsplay.ByteSize.parse("200MB")
      {:ok, 200_000_000}

      iex> Deepsplay.ByteSize.parse("1.5 GiB")
      {:ok, 1_610_612_736}

      iex> Deepsplay.ByteSize.parse("64kB")
      {:ok, 64_000}

      iex> Deepsplay.ByteSize.parse("20mb")
      :error
  """
  @spec parse(term()) :: {:ok, pos_integer()} | :error
  def parse(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse(value) when is_binary(value) do
    with [_all, number, unit] <-
           Regex.run(~r/^\s*(\d+(?:\.\d+)?)\s*([A-Za-z]*)\s*$/, value),
         {:ok, factor} <- Map.fetch(@units, if(unit == "", do: "B", else: unit)),
         bytes when bytes >= 1 <- floor(String.to_float(decimal(number)) * factor) do
      {:ok, bytes}
    else
      _other -> :error
    end
  end

  def parse(_value), do: :error

  defp decimal(number), do: if(String.contains?(number, "."), do: number, else: number <> ".0")

  @doc """
  Formats a size in SI units for display.

      iex> Deepsplay.ByteSize.format(200_000_000)
      "200.0 MB"

      iex> Deepsplay.ByteSize.format(1_536)
      "1.5 kB"

      iex> Deepsplay.ByteSize.format(512)
      "512 B"
  """
  @spec format(non_neg_integer()) :: String.t()
  def format(size) when size >= 1_000_000_000, do: "#{Float.round(size / 1_000_000_000, 1)} GB"
  def format(size) when size >= 1_000_000, do: "#{Float.round(size / 1_000_000, 1)} MB"
  def format(size) when size >= 1_000, do: "#{Float.round(size / 1_000, 1)} kB"
  def format(size), do: "#{size} B"
end
