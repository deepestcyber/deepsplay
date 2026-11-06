defmodule Deepsplay.RevisionStore do
  @moduledoc """
  The on-disk revision cache, keyed by commit SHA (ADR 6).

  Layout per repository, below the cache directory:

      <repo-key>/
        mirror.git/     bare repository, shallow fetches only
        rev/<sha>/      exported tree of one revision, no .git
        refs/<ref>      last good SHA for a ref (URL-encoded file name)
        history         published SHAs, oldest first
        tmp/            work in progress, emptied when the writer starts

  All writes for one repository go through one process
  (`Deepsplay.RevisionStore.Writer`), so concurrent requests for the same
  revision wait for the running fetch instead of starting another. Reads
  (`last_good/3`, `revision_dir/3`) go straight to the disk.

  ## Common options

    * `:cache_dir` - defaults to the `cache_dir` of the host configuration
  """

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RepoUrl
  alias Deepsplay.RevisionStore.Writer

  @type error ::
          {:config, String.t()}
          | {:fetch, String.t()}
          | {:rejected, sha :: String.t(), String.t()}

  @doc """
  Fetches `ref` of the repository at `url` and publishes its commit, unless
  that revision is already in the cache. Remembers it as the last good SHA for
  `ref` (or the `:remember_as` key).

  ## Options

    * `:validate` - `fun(dir) -> :ok | {:error, message}`, called with the
      revision's tree before it is published, and also when the revision is
      already in the cache (another caller may have validated it differently).
      A rejected revision is never remembered and the last good SHA stays.
    * `:remember_as` - key for the last good SHA, default `ref`. Callers that
      validate differently use separate keys, so each keeps its own last good
      revision.
    * `:git` - options passed to `Deepsplay.Git.run/2`, such as `:timeout`
    * `:transports` - allowed git transports; defaults to
      `Deepsplay.HostConfig.allowed_transports/0`
  """
  @spec publish(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def publish(url, ref, opts \\ []) do
    transports = Keyword.get_lazy(opts, :transports, &HostConfig.allowed_transports/0)

    with {:ok, cache_dir} <- cache_dir(opts),
         :ok <- check_url(url, transports),
         :ok <- check_ref(ref),
         {:ok, writer} <- Writer.ensure_started(cache_dir, url) do
      validate = Keyword.get(opts, :validate, fn _dir -> :ok end)
      remember_as = Keyword.get(opts, :remember_as, ref)
      git_opts = Keyword.put(Keyword.get(opts, :git, []), :transports, transports)
      Writer.publish(writer, ref, remember_as, validate, git_opts)
    end
  end

  @doc """
  Returns the last good SHA remembered under `key` (a ref, or a `:remember_as`
  key of `publish/3`), if its revision is still in the cache. Needs no network,
  so it can be served right after a restart.
  """
  @spec last_good(String.t(), String.t(), keyword()) :: {:ok, String.t()} | :error
  def last_good(url, key, opts \\ []) do
    with {:ok, cache_dir} <- cache_dir(opts),
         repo_dir = repo_dir(cache_dir, url),
         {:ok, content} <- File.read(ref_file(repo_dir, key)),
         sha = String.trim(content),
         true <- File.dir?(Path.join([repo_dir, "rev", sha])) do
      {:ok, sha}
    else
      _ -> :error
    end
  end

  @doc """
  Returns the directory holding the exported tree of revision `sha`.
  """
  @spec revision_dir(String.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, error()}
  def revision_dir(url, sha, opts \\ []) do
    with {:ok, cache_dir} <- cache_dir(opts) do
      {:ok, Path.join([repo_dir(cache_dir, url), "rev", sha])}
    end
  end

  @doc """
  Deletes old revisions of a repository. Keeps the SHAs in `in_use` plus the
  most recently published others, up to `:keep` (defaults to `keep_revisions`
  of the host configuration).
  """
  @spec prune(String.t(), [String.t()], keyword()) :: :ok | {:error, error()}
  def prune(url, in_use, opts \\ []) do
    with {:ok, cache_dir} <- cache_dir(opts),
         {:ok, keep} <- keep_revisions(opts),
         {:ok, writer} <- Writer.ensure_started(cache_dir, url) do
      Writer.prune(writer, in_use, keep)
    end
  end

  @doc """
  Deletes the directories of all repositories not in `urls`.
  """
  @spec prune_repositories([String.t()], keyword()) :: :ok | {:error, error()}
  def prune_repositories(urls, opts \\ []) do
    with {:ok, cache_dir} <- cache_dir(opts) do
      keep = MapSet.new(urls, &RepoUrl.key/1)

      for entry <- ls(cache_dir), entry not in keep do
        Writer.stop(cache_dir, entry)
        File.rm_rf!(Path.join(cache_dir, entry))
      end

      :ok
    end
  end

  @doc false
  def repo_dir(cache_dir, url), do: Path.join(cache_dir, RepoUrl.key(url))

  @doc false
  def ref_file(repo_dir, key), do: Path.join([repo_dir, "refs", URI.encode_www_form(key)])

  @doc """
  Formats an error for logs, the status page and the fallback page.
  """
  @spec format_error(error()) :: String.t()
  def format_error({:config, message}), do: message
  def format_error({:fetch, message}), do: "fetch failed: #{message}"

  def format_error({:rejected, sha, message}),
    do: "revision #{String.slice(sha, 0, 12)} rejected: #{message}"

  defp cache_dir(opts) do
    case Keyword.fetch(opts, :cache_dir) do
      {:ok, dir} ->
        {:ok, dir}

      :error ->
        case Store.get() do
          {:ok, host_config} -> {:ok, host_config.cache_dir}
          {:error, _errors} -> {:error, {:config, "host configuration unusable"}}
        end
    end
  end

  defp keep_revisions(opts) do
    case Keyword.fetch(opts, :keep) do
      {:ok, keep} ->
        {:ok, keep}

      :error ->
        case Store.get() do
          {:ok, host_config} -> {:ok, host_config.keep_revisions}
          {:error, _errors} -> {:error, {:config, "host configuration unusable"}}
        end
    end
  end

  defp check_url(url, transports) do
    case RepoUrl.transport(url) do
      {:ok, transport} ->
        if transport in transports,
          do: :ok,
          else: {:error, {:config, ~s(transport "#{transport}" is not allowed)}}

      :error ->
        {:error, {:config, "unsupported repository URL"}}
    end
  end

  # Refs end up on git's command line and in file names.
  defp check_ref(ref) do
    if Regex.match?(~r{^[A-Za-z0-9._][A-Za-z0-9._/-]*$}, ref) and
         not String.contains?(ref, "..") do
      :ok
    else
      {:error, {:config, "invalid ref #{inspect(ref)}"}}
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end
end
