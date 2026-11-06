defmodule Deepsplay.TomlSchemaTest do
  use ExUnit.Case, async: true

  alias Deepsplay.TomlSchema

  test "fields/3 reads values, applies defaults and reports problems" do
    specs = [
      {"name", :name, :string, []},
      {"count", :count, :non_neg_integer, default: 3},
      {"mode", :mode, {:enum, ["a", "b"]}, []},
      {"upper", :upper, fn v -> {:ok, String.upcase(v)} end, []}
    ]

    assert {%{name: "x", count: 3, mode: "a", upper: "Y"}, []} =
             TomlSchema.fields(%{"name" => "x", "mode" => "a", "upper" => "y"}, "t", specs)

    assert {_values, errors} = TomlSchema.fields(%{"mode" => "c", "extra" => 1}, "t", specs)

    assert errors == [
             "t.name is missing",
             ~s(t.mode must be one of: "a", "b"),
             "t.upper is missing",
             ~s(t: unknown key "extra")
           ]
  end

  test "cast/2 for numbers and paths" do
    assert TomlSchema.cast(:positive_number, 2) == {:ok, 2.0}
    assert TomlSchema.cast(:positive_number, 0.5) == {:ok, 0.5}
    assert {:error, _} = TomlSchema.cast(:positive_number, 0)
    assert {:error, _} = TomlSchema.cast(:positive_number, "1")

    assert TomlSchema.cast(:relative_path, "a/b.html") == {:ok, "a/b.html"}
    assert {:error, _} = TomlSchema.cast(:relative_path, "")
    assert {:error, _} = TomlSchema.cast(:relative_path, "/a")
    assert {:error, _} = TomlSchema.cast(:relative_path, "a/../../b")
  end
end
