defmodule Deepsplay.Pages do
  @moduledoc """
  Page documentation (ADR 14) and the helper index (ADR 15) of a revision,
  read once and kept in memory.

  Entries are keyed by the `pages/` directory and a revision key: the commit
  SHA, or for a local directory its version token, which changes with every
  change (ADR 12). Both make a cached entry valid for as long as the key is.
  """

  use GenServer

  alias Deepsplay.HelperIndex
  alias Deepsplay.PageDoc
  alias Deepsplay.RevisionFile

  @table __MODULE__
  @max_entries 1_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The helper index of a revision.
  """
  @spec index(Path.t(), String.t()) :: HelperIndex.t()
  def index(pages_dir, key) do
    cached({:index, pages_dir, key}, fn -> HelperIndex.build(pages_dir) end)
  end

  @doc """
  All HTML files (`.html`, `.htm`) below `pages/`, relative to it and sorted;
  hidden files and symlinks are left out, as they are never served.
  """
  @spec files(Path.t(), String.t()) :: [String.t()]
  def files(pages_dir, key) do
    cached({:files, pages_dir, key}, fn ->
      ["**/*.html", "**/*.htm"]
      |> Enum.flat_map(&Path.wildcard(Path.join(pages_dir, &1)))
      |> Enum.map(&Path.relative_to(&1, pages_dir))
      |> Enum.filter(&match?({:ok, _}, RevisionFile.resolve(pages_dir, &1)))
      |> Enum.sort()
    end)
  end

  @doc """
  The documentation of a page, by its path relative to `pages/` (without
  query). `:none` for an undocumented page; `:error` if the path is not a
  deliverable file.
  """
  @spec doc(Path.t(), String.t(), String.t()) :: {:ok, PageDoc.t()} | :none | :error
  def doc(pages_dir, key, path) do
    cached({:doc, pages_dir, key, path}, fn ->
      with {:ok, file} <- RevisionFile.resolve(pages_dir, path),
           {:ok, doc} <- PageDoc.read(file) do
        {:ok, doc}
      else
        :none -> :none
        _error -> :error
      end
    end)
  end

  @doc false
  # Forgets everything; for tests.
  def clear, do: :ets.delete_all_objects(@table)

  defp cached(key, compute) do
    case :ets.lookup(@table, key) do
      [{^key, value}] ->
        value

      [] ->
        value = compute.()
        # Old revisions are not tracked; a full table simply starts over.
        if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
        :ets.insert(@table, {key, value})
        value
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
