defmodule Deepsplay.Screen.GlobTest do
  use ExUnit.Case, async: true

  alias Deepsplay.Screen.Glob

  doctest Glob

  defp matches(pattern, paths) do
    {:ok, glob} = Glob.compile(pattern)
    Enum.filter(paths, &Glob.match?(glob, &1))
  end

  @paths ["a.html", "b.htm", "x/a.html", "x/y/a.html", "x.y/a.html", "a+b.html"]

  test "* and ? stay within one segment" do
    assert matches("*.html", @paths) == ["a.html", "a+b.html"]
    assert matches("?.html", @paths) == ["a.html"]
    assert matches("*/a.html", @paths) == ["x/a.html", "x.y/a.html"]
  end

  test "** spans directories, at the start, middle or end" do
    assert matches("**/a.html", @paths) == ["a.html", "x/a.html", "x/y/a.html", "x.y/a.html"]
    assert matches("x/**/a.html", @paths) == ["x/a.html", "x/y/a.html"]
    assert matches("x/**", @paths) == ["x/a.html", "x/y/a.html"]
  end

  test "other characters match themselves" do
    assert matches("a+b.html", @paths) == ["a+b.html"]
    assert matches("x.y/*", @paths) == ["x.y/a.html"]
  end

  test "patterns must be relative, inside pages/ and well-formed" do
    for {pattern, why} <- [
          {"", "must not be empty"},
          {"/a.html", "must be relative to pages/"},
          {"../a.html", "must not leave pages/ (..)"},
          {"x/../a.html", "must not leave pages/ (..)"},
          {"x//a.html", "must not have empty or . segments"},
          {"./a.html", "must not have empty or . segments"},
          {"x\\a.html", "must not contain \\ or NUL"},
          {"x**.html", "may use ** only as a whole segment"},
          {"{a,b.html", "has an unclosed {"},
          {"a}.html", "has a } without {"},
          {"{a,{b}}.html", "must not nest { }"}
        ] do
      assert Glob.compile(pattern) == {:error, why}, pattern
    end
  end
end
