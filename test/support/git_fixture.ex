defmodule Deepsplay.GitFixture do
  @moduledoc """
  Builds local git repositories for tests, reachable over `file://` (ADR 6).
  """

  @env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"}
  ]

  @doc """
  Creates a repository in `dir` with branch `main` and returns its `file://`
  URL.
  """
  def init(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "--quiet", "--initial-branch", "main"])
    "file://" <> dir
  end

  @doc """
  Writes `files` (`%{path => content}`) into the repository, commits them and
  returns the commit SHA.
  """
  def commit(dir, files, message \\ "update") do
    for {path, content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    git!(dir, ["add", "--all"])
    git!(dir, ["commit", "--quiet", "--allow-empty", "--message", message])
    head(dir)
  end

  @doc """
  Adds a symlink and commits it, returning the commit SHA.
  """
  def commit_symlink(dir, link, target) do
    File.ln_s!(target, Path.join(dir, link))
    git!(dir, ["add", "--all"])
    git!(dir, ["commit", "--quiet", "--message", "add symlink"])
    head(dir)
  end

  @doc "Runs a git command in the repository."
  def git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, env: @env, stderr_to_stdout: true)
    out
  end

  @doc "Returns the SHA of HEAD."
  def head(dir), do: dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
end
