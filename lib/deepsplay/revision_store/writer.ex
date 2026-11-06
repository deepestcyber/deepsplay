defmodule Deepsplay.RevisionStore.Writer do
  @moduledoc """
  The single writer of one repository's cache directory.

  Started on demand, one per cache directory and repository URL. See
  `Deepsplay.RevisionStore` for the layout.
  """

  use GenServer, restart: :temporary

  alias Deepsplay.Git
  alias Deepsplay.RepoUrl
  alias Deepsplay.RevisionStore

  @registry Deepsplay.RevisionStore.Registry
  @supervisor Deepsplay.RevisionStore.Supervisor

  @doc false
  def ensure_started(cache_dir, url) do
    key = {cache_dir, RepoUrl.key(url)}

    # The registry drops a stopped writer asynchronously, so a lookup can
    # still return its pid for a moment.
    case Registry.lookup(@registry, key) |> Enum.filter(fn {pid, _} -> Process.alive?(pid) end) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {key, cache_dir, url}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:config, "cannot start writer: #{inspect(reason)}"}}
        end
    end
  end

  @doc false
  def stop(cache_dir, repo_key) do
    case Registry.lookup(@registry, {cache_dir, repo_key}) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end

  @doc false
  def publish(writer, ref, validate, git_opts),
    do: GenServer.call(writer, {:publish, ref, validate, git_opts}, :infinity)

  @doc false
  def prune(writer, in_use, keep), do: GenServer.call(writer, {:prune, in_use, keep}, :infinity)

  @doc false
  def start_link({key, cache_dir, url}) do
    GenServer.start_link(__MODULE__, {cache_dir, url}, name: {:via, Registry, {@registry, key}})
  end

  @impl true
  def init({cache_dir, url}) do
    repo_dir = RevisionStore.repo_dir(cache_dir, url)

    ensure_dirs(repo_dir)
    clean_tmp(repo_dir)

    {:ok, %{url: url, repo_dir: repo_dir}}
  end

  @impl true
  def handle_call({:publish, ref, validate, git_opts}, _from, state) do
    # The directories may have been removed while the writer was running.
    ensure_dirs(state.repo_dir)

    result =
      with {:ok, sha} <- fetch(state, ref, git_opts),
           :ok <- export(state, sha, validate, git_opts) do
        remember(state.repo_dir, ref, sha)
        {:ok, sha}
      end

    clean_tmp(state.repo_dir)
    {:reply, result, state}
  end

  def handle_call({:prune, in_use, keep}, _from, state) do
    ensure_dirs(state.repo_dir)
    {:reply, do_prune(state.repo_dir, in_use, keep), state}
  end

  defp fetch(state, ref, git_opts) do
    mirror = Path.join(state.repo_dir, "mirror.git")

    with :ok <- init_mirror(mirror, git_opts),
         {:ok, _out} <-
           git(
             [
               "fetch",
               "--quiet",
               "--depth",
               "1",
               "--no-tags",
               "--no-recurse-submodules",
               "--end-of-options",
               state.url,
               ref
             ],
             mirror,
             git_opts
           ),
         {:ok, out} <- git(["rev-parse", "--verify", "FETCH_HEAD^{commit}"], mirror, git_opts) do
      {:ok, String.trim(out)}
    else
      {:error, error} -> {:error, {:fetch, Git.format_error(error)}}
    end
  end

  defp init_mirror(mirror, git_opts) do
    if File.dir?(mirror) do
      :ok
    else
      with {:ok, _out} <- Git.run(["init", "--quiet", "--bare", mirror], git_opts), do: :ok
    end
  end

  defp export(state, sha, validate, git_opts) do
    rev_dir = Path.join([state.repo_dir, "rev", sha])

    if File.dir?(rev_dir) do
      :ok
    else
      tmp = Path.join(state.repo_dir, "tmp")
      tar = Path.join(tmp, "#{sha}.tar")
      tree = Path.join(tmp, sha)
      mirror = Path.join(state.repo_dir, "mirror.git")

      with {:ok, _out} <- archive(mirror, sha, tar, git_opts),
           :ok <- check_entries(tar, sha),
           :ok <- extract(tar, tree, sha),
           :ok <- run_validate(validate, tree, sha) do
        File.rename!(tree, rev_dir)
        :ok
      end
    end
  end

  defp archive(mirror, sha, tar, git_opts) do
    case git(["archive", "--format=tar", "-o", tar, sha], mirror, git_opts) do
      {:ok, out} -> {:ok, out}
      {:error, error} -> {:error, {:fetch, "export failed: " <> Git.format_error(error)}}
    end
  end

  # Symlinks could point outside the revision directory (ADR 6).
  defp check_entries(tar, sha) do
    case :erl_tar.table(String.to_charlist(tar), [:verbose]) do
      {:ok, entries} ->
        bad =
          for {name, type, _size, _mtime, _mode, _uid, _gid} <- entries,
              type in [:symlink, :link] or unsafe_path?(to_string(name)),
              do: to_string(name)

        case bad do
          [] ->
            :ok

          bad ->
            {:error, {:rejected, sha, "contains symlinks: #{Enum.join(Enum.take(bad, 5), ", ")}"}}
        end

      {:error, reason} ->
        {:error, {:rejected, sha, "unreadable export: #{inspect(reason)}"}}
    end
  end

  defp unsafe_path?(name), do: Path.type(name) != :relative or ".." in Path.split(name)

  defp extract(tar, tree, sha) do
    File.mkdir_p!(tree)

    case :erl_tar.extract(String.to_charlist(tar), [{:cwd, String.to_charlist(tree)}]) do
      :ok -> File.rm!(tar)
      {:error, reason} -> {:error, {:rejected, sha, "cannot extract: #{inspect(reason)}"}}
    end
  end

  defp run_validate(validate, tree, sha) do
    case validate.(tree) do
      :ok -> :ok
      {:error, message} -> {:error, {:rejected, sha, message}}
    end
  end

  defp remember(repo_dir, ref, sha) do
    write_atomically(RevisionStore.ref_file(repo_dir, ref), sha <> "\n")

    history = read_history(repo_dir)

    if List.last(history) != sha do
      write_history(repo_dir, Enum.reject(history, &(&1 == sha)) ++ [sha])
    end
  end

  defp do_prune(repo_dir, in_use, keep) do
    history = read_history(repo_dir)

    recent =
      history
      |> Enum.reverse()
      |> Enum.reject(&(&1 in in_use))
      |> Enum.take(keep)

    kept = MapSet.new(in_use ++ recent)
    rev = Path.join(repo_dir, "rev")

    for sha <- ls(rev), sha not in kept do
      File.rm_rf!(Path.join(rev, sha))
    end

    refs = Path.join(repo_dir, "refs")

    for name <- ls(refs) do
      path = Path.join(refs, name)
      if String.trim(File.read!(path)) not in kept, do: File.rm!(path)
    end

    write_history(repo_dir, Enum.filter(history, &(&1 in kept)))
    :ok
  end

  defp read_history(repo_dir) do
    case File.read(Path.join(repo_dir, "history")) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp write_history(repo_dir, shas) do
    write_atomically(Path.join(repo_dir, "history"), Enum.map(shas, &[&1, "\n"]))
  end

  defp write_atomically(path, content) do
    tmp = path <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end

  defp ensure_dirs(repo_dir) do
    for dir <- ["rev", "refs", "tmp"], do: File.mkdir_p!(Path.join(repo_dir, dir))
  end

  defp clean_tmp(repo_dir) do
    tmp = Path.join(repo_dir, "tmp")
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
  end

  defp git(args, mirror, git_opts), do: Git.run(["-C", mirror | args], git_opts)

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end
end
