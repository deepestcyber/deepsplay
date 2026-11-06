defmodule Deepsplay.RemoteRef do
  @moduledoc """
  Finds out which commit a ref of a remote repository points to, with one
  `git ls-remote` call that transfers no objects (ADR 7).
  """

  alias Deepsplay.Git
  alias Deepsplay.RevisionFile

  @type kind :: :branch | :tag | :sha

  @doc """
  Resolves `ref` of the repository at `url` to a commit SHA.

  Returns the kind of ref as well: only branches move and need polling. A full
  SHA is returned as is, without network access. For an annotated tag, the
  commit it points to is returned.
  """
  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, %{sha: String.t(), kind: kind()}} | {:error, String.t()}
  def resolve(url, ref, git_opts \\ []) do
    if RevisionFile.sha?(ref) do
      {:ok, %{sha: ref, kind: :sha}}
    else
      branch = "refs/heads/" <> ref
      tag = "refs/tags/" <> ref
      peeled = tag <> "^{}"

      case Git.run(["ls-remote", url, branch, tag, peeled], git_opts) do
        {:ok, output} -> pick(parse(output), branch, tag, peeled, ref)
        {:error, error} -> {:error, Git.format_error(error)}
      end
    end
  end

  defp parse(output) do
    for line <- String.split(output, "\n", trim: true),
        [sha, name] <- [String.split(line, "\t", parts: 2)],
        into: %{},
        do: {name, sha}
  end

  defp pick(refs, branch, tag, peeled, ref) do
    cond do
      sha = refs[branch] -> {:ok, %{sha: sha, kind: :branch}}
      sha = refs[peeled] -> {:ok, %{sha: sha, kind: :tag}}
      sha = refs[tag] -> {:ok, %{sha: sha, kind: :tag}}
      true -> {:error, ~s(ref "#{ref}" not found)}
    end
  end
end
