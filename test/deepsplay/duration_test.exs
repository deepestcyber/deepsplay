defmodule Deepsplay.DurationTest do
  use ExUnit.Case, async: true

  alias Deepsplay.Duration

  doctest Duration

  test "parse/1 accepts all units" do
    assert Duration.parse("250ms") == {:ok, 250}
    assert Duration.parse("45s") == {:ok, 45_000}
    assert Duration.parse("5m") == {:ok, 300_000}
    assert Duration.parse("2h") == {:ok, 7_200_000}
  end

  test "parse/1 rejects anything else" do
    for value <- ["", "30", "1.5s", "-1s", "30 s", "1d", 30, nil] do
      assert Duration.parse(value) == :error, inspect(value)
    end
  end
end
