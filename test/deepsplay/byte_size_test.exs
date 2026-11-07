defmodule Deepsplay.ByteSizeTest do
  use ExUnit.Case, async: true

  alias Deepsplay.ByteSize

  doctest ByteSize

  test "SI and binary units, bytes and plain numbers" do
    for {text, bytes} <- [
          {"1B", 1},
          {"500", 500},
          {"1kB", 1_000},
          {"1KB", 1_000},
          {"1MB", 1_000_000},
          {"1GB", 1_000_000_000},
          {"1KiB", 1_024},
          {"1MiB", 1_048_576},
          {"1GiB", 1_073_741_824},
          {" 20 MB ", 20_000_000},
          {"0.5kB", 500},
          {"1.0009kB", 1_000}
        ] do
      assert ByteSize.parse(text) == {:ok, bytes}, text
    end

    assert ByteSize.parse(4096) == {:ok, 4096}
  end

  test "refuses other spellings, zero and nonsense" do
    for value <- [
          "20mb",
          "20Mb",
          "20 megabytes",
          "1 TB",
          "-1MB",
          "0",
          "0.4B",
          "MB",
          "",
          "1,5MB",
          0,
          -1,
          1.5,
          nil
        ] do
      assert ByteSize.parse(value) == :error, inspect(value)
    end
  end

  test "formats in SI units" do
    assert ByteSize.format(0) == "0 B"
    assert ByteSize.format(999) == "999 B"
    assert ByteSize.format(1_000) == "1.0 kB"
    assert ByteSize.format(3_100_000) == "3.1 MB"
    assert ByteSize.format(1_500_000_000) == "1.5 GB"
  end
end
