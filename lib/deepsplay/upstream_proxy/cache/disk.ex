defmodule Deepsplay.UpstreamProxy.Cache.Disk do
  @moduledoc """
  Keeps upstream cache entries on disk (ADR 20), so a restart or deploy does
  not cause a burst of upstream calls.

  One file per entry, named by a hash of its key. Writes and deletes run in
  this process, in the order the cache sends them, so the cache never waits
  for the disk. Times are stored as wall-clock milliseconds.
  """

  use GenServer

  require Logger

  @type entry :: %{
          key: term(),
          value: term(),
          fetched: integer(),
          expires: integer(),
          keep: integer()
        }

  @doc false
  def start_link(dir), do: GenServer.start_link(__MODULE__, dir)

  @doc """
  Reads all entries from `dir`. Unreadable files are deleted.
  """
  @spec load(Path.t()) :: [entry()]
  def load(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        for file <- files, String.ends_with?(file, ".entry"), record = read(dir, file), do: record

      {:error, _reason} ->
        []
    end
  end

  @doc "Writes an entry in the background."
  @spec write(pid(), entry()) :: :ok
  def write(disk, record), do: GenServer.cast(disk, {:write, record})

  @doc "Deletes an entry in the background."
  @spec delete(pid(), term()) :: :ok
  def delete(disk, key), do: GenServer.cast(disk, {:delete, key})

  @doc "Deletes all entries in the background."
  @spec delete_all(pid()) :: :ok
  def delete_all(disk), do: GenServer.cast(disk, :delete_all)

  @doc "Waits until everything sent before is on disk."
  @spec sync(pid()) :: :ok
  def sync(disk), do: GenServer.call(disk, :sync, :infinity)

  @doc false
  def path(dir, key) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(key))
    Path.join(dir, Base.url_encode64(hash, padding: false) <> ".entry")
  end

  defp read(dir, file) do
    path = Path.join(dir, file)

    with {:ok, binary} <- File.read(path),
         %{key: _, value: _, fetched: _, expires: _, keep: _} = record <- decode(binary) do
      record
    else
      _unreadable ->
        File.rm(path)
        nil
    end
  end

  defp decode(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(dir) do
    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:stop, :file.format_error(reason)}
    end
  end

  @impl true
  def handle_cast({:write, record}, dir) do
    path = path(dir, record.key)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, :erlang.term_to_binary(record)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        Logger.warning("upstream cache: cannot write #{path}: #{:file.format_error(reason)}")
    end

    {:noreply, dir}
  end

  def handle_cast({:delete, key}, dir) do
    File.rm(path(dir, key))
    {:noreply, dir}
  end

  def handle_cast(:delete_all, dir) do
    for file <- File.ls!(dir), do: File.rm(Path.join(dir, file))
    {:noreply, dir}
  end

  @impl true
  def handle_call(:sync, _from, dir), do: {:reply, :ok, dir}
end
