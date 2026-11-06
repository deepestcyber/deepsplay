defmodule Deepsplay.RevisionFile do
  @moduledoc """
  Resolves a path inside a revision to a file on disk, safely (ADR 6, ADR 10).

  Only regular files below the root are found: no `..`, no absolute paths, no
  hidden files or directories (names starting with `.`), no symlinks anywhere
  on the way, no directories.
  """

  @doc """
  Resolves `path` (a relative path string or a list of segments) below `root`.

      iex> Deepsplay.RevisionFile.resolve("/srv/rev", "../etc/passwd")
      :error
  """
  @spec resolve(Path.t(), String.t() | [String.t()]) :: {:ok, Path.t()} | :error
  def resolve(root, path) when is_binary(path), do: resolve(root, String.split(path, "/"))

  def resolve(root, segments) when is_list(segments) do
    if segments != [] and Enum.all?(segments, &valid_segment?/1) do
      walk(root, segments)
    else
      :error
    end
  end

  @doc """
  Returns true if any segment of `path` is hidden (starts with `.`).

      iex> Deepsplay.RevisionFile.hidden?("a/.env")
      true
  """
  @spec hidden?(String.t() | [String.t()]) :: boolean()
  def hidden?(path) when is_binary(path), do: hidden?(String.split(path, "/"))

  def hidden?(segments) when is_list(segments),
    do: Enum.any?(segments, &String.starts_with?(&1, "."))

  @doc """
  Returns true if `sha` looks like a full commit SHA (SHA-1 or SHA-256).
  """
  @spec sha?(String.t()) :: boolean()
  def sha?(sha) when is_binary(sha), do: Regex.match?(~r/^([0-9a-f]{40}|[0-9a-f]{64})$/, sha)
  def sha?(_sha), do: false

  defp valid_segment?(segment) do
    segment != "" and not String.starts_with?(segment, ".") and
      not String.contains?(segment, ["/", "\\", <<0>>])
  end

  # Every component is checked with lstat, so a symlink on the way is never
  # followed, even if one slipped past the export.
  defp walk(dir, [last]) do
    path = Path.join(dir, last)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      _other -> :error
    end
  end

  defp walk(dir, [segment | rest]) do
    path = Path.join(dir, segment)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, rest)
      _other -> :error
    end
  end
end
