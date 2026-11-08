defmodule Deepsplay.Screen.Glob do
  @moduledoc """
  Patterns naming pages in a manifest (ADR 28), relative to `pages/`:
  `*` and `?` match within one path segment, `**` across directories,
  `{a,b}` alternatives. Everything else matches itself.

      iex> {:ok, glob} = Deepsplay.Screen.Glob.compile("small/*.html")
      iex> Deepsplay.Screen.Glob.match?(glob, "small/clock.html")
      true
      iex> Deepsplay.Screen.Glob.match?(glob, "small/more/clock.html")
      false

      iex> {:ok, glob} = Deepsplay.Screen.Glob.compile("**/{a,b}?.html")
      iex> Enum.filter(["a1.html", "x/b2.html", "x/c3.html"], &Deepsplay.Screen.Glob.match?(glob, &1))
      ["a1.html", "x/b2.html"]
  """

  @opaque t :: Regex.t()

  @doc """
  Compiles a pattern. Patterns must be relative and stay inside `pages/`.
  """
  @spec compile(String.t()) :: {:ok, t()} | {:error, String.t()}
  def compile(pattern) when is_binary(pattern) do
    segments = String.split(pattern, "/")

    cond do
      pattern == "" -> {:error, "must not be empty"}
      String.starts_with?(pattern, "/") -> {:error, "must be relative to pages/"}
      ".." in segments -> {:error, "must not leave pages/ (..)"}
      Enum.any?(segments, &(&1 in ["", "."])) -> {:error, "must not have empty or . segments"}
      String.contains?(pattern, ["\\", <<0>>]) -> {:error, "must not contain \\ or NUL"}
      true -> translate(segments)
    end
  end

  @doc "Returns true if `path` (relative to `pages/`) matches."
  @spec match?(t(), String.t()) :: boolean()
  def match?(regex, path), do: Regex.match?(regex, path)

  defp translate(segments) do
    last = length(segments) - 1

    segments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, ""}, fn
      # `**` as a whole segment: any number of directories, or (at the end)
      # anything below.
      {"**", ^last}, {:ok, acc} ->
        {:cont, {:ok, acc <> ".+"}}

      {"**", _i}, {:ok, acc} ->
        {:cont, {:ok, acc <> "(?:[^/]+/)*"}}

      {segment, i}, {:ok, acc} ->
        case segment(segment) do
          {:ok, source} ->
            {:cont, {:ok, acc <> source <> if(i == last, do: "", else: "/")}}

          {:error, why} ->
            {:halt, {:error, why}}
        end
    end)
    |> case do
      {:ok, source} -> {:ok, Regex.compile!("\\A" <> source <> "\\z", "u")}
      error -> error
    end
  end

  defp segment(segment), do: segment(String.graphemes(segment), "", false)

  defp segment([], acc, false), do: {:ok, acc}
  defp segment([], _acc, true), do: {:error, "has an unclosed {"}
  defp segment(["*", "*" | _rest], _acc, _alt), do: {:error, "may use ** only as a whole segment"}
  defp segment(["*" | rest], acc, alt), do: segment(rest, acc <> "[^/]*", alt)
  defp segment(["?" | rest], acc, alt), do: segment(rest, acc <> "[^/]", alt)
  defp segment(["{" | _rest], _acc, true), do: {:error, "must not nest { }"}
  defp segment(["{" | rest], acc, false), do: segment(rest, acc <> "(?:", true)
  defp segment(["," | rest], acc, true), do: segment(rest, acc <> "|", true)
  defp segment(["}" | rest], acc, true), do: segment(rest, acc <> ")", false)
  defp segment(["}" | _rest], _acc, false), do: {:error, "has a } without {"}
  defp segment([char | rest], acc, alt), do: segment(rest, acc <> Regex.escape(char), alt)
end
