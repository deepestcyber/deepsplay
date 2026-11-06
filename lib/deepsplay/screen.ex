defmodule Deepsplay.Screen do
  @moduledoc """
  The manifest of a revision: `screen.toml` at the root of the repository, or
  of the configured `subdir`. It lists the pages and how they rotate
  (ADR 5, ADR 9).

  The manifest is data only. It is validated before a revision is published,
  and a revision that fails is never published.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.Screen.Page
  alias Deepsplay.TomlSchema

  @file_name "screen.toml"
  @max_size 64 * 1024

  defstruct title: nil, rotation: :sequential, pages: [], warnings: []

  @type t :: %__MODULE__{
          title: String.t() | nil,
          rotation: :sequential | :random,
          pages: [Page.t(), ...],
          warnings: [String.t()]
        }

  @top_fields [
    {"title", :title, :string, default: nil},
    {"rotation", :rotation, {:enum, ["sequential", "random"]}, default: "sequential"}
  ]

  @page_fields [
    {"path", :path, :relative_path, []},
    {"duration", :duration, :duration, []},
    {"weight", :weight, :positive_number, default: 1.0},
    {"uses", :uses, :string_list, default: []}
  ]

  @doc """
  Returns the directory holding `screen.toml` for `config` in the revision
  directory `rev_dir`.
  """
  @spec root(Path.t(), Config.t()) :: Path.t()
  def root(rev_dir, %Config{subdir: ""}), do: rev_dir
  def root(rev_dir, %Config{subdir: subdir}), do: Path.join(rev_dir, subdir)

  @doc """
  Returns a validator for `Deepsplay.RevisionStore.publish/3`: it accepts a
  revision only if its manifest is valid for `config`.
  """
  @spec validator(Config.t()) :: (Path.t() -> :ok | {:error, String.t()})
  def validator(%Config{} = config) do
    fn rev_dir ->
      root = root(rev_dir, config)

      if File.dir?(root) do
        case load(root, upstreams: config.upstreams) do
          {:ok, _screen} -> :ok
          {:error, errors} -> {:error, Enum.join(errors, "; ")}
        end
      else
        {:error, ~s(subdir "#{config.subdir}" does not exist)}
      end
    end
  end

  @doc """
  Reads and validates `screen.toml` in `root`.

  Every page `path` must name a regular file below `root`.

  ## Options

    * `:upstreams` - upstreams the configuration may use; a page that `uses`
      any other is an error
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def load(root, opts \\ []) do
    path = Path.join(root, @file_name)

    with {:ok, toml} <- read(path),
         {:ok, data} <- decode(toml) do
      build(data, root, Keyword.get(opts, :upstreams, []))
    end
  end

  defp read(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_size ->
        {:error, ["#{@file_name} is larger than #{div(@max_size, 1024)} KiB"]}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, toml} ->
            {:ok, toml}

          {:error, reason} ->
            {:error, ["cannot read #{@file_name}: #{:file.format_error(reason)}"]}
        end

      {:ok, %File.Stat{}} ->
        {:error, ["#{@file_name} is not a regular file"]}

      {:error, :enoent} ->
        {:error, ["#{@file_name} is missing"]}

      {:error, reason} ->
        {:error, ["cannot read #{@file_name}: #{:file.format_error(reason)}"]}
    end
  end

  defp decode(toml) do
    case TomlElixir.decode(toml) do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, ["#{@file_name} is invalid TOML: #{Exception.message(error)}"]}
    end
  end

  defp build(data, root, upstreams) do
    # `page` and `backend` are read separately; everything else is checked as
    # top-level fields, including unknown keys.
    {top, top_errors} =
      TomlSchema.fields(Map.drop(data, ["page", "backend"]), "screen", @top_fields)

    {pages, page_errors} = pages(Map.get(data, "page"), root, upstreams)

    warnings =
      if Map.has_key?(data, "backend"),
        do: ["[backend] is not supported yet and is ignored"],
        else: []

    case top_errors ++ page_errors do
      [] ->
        {:ok,
         %__MODULE__{
           title: top.title,
           rotation: rotation(top.rotation),
           pages: pages,
           warnings: warnings
         }}

      errors ->
        {:error, errors}
    end
  end

  defp rotation("sequential"), do: :sequential
  defp rotation("random"), do: :random

  defp pages(nil, _root, _upstreams), do: {[], ["at least one [[page]] is required"]}
  defp pages([], _root, _upstreams), do: {[], ["at least one [[page]] is required"]}

  defp pages(pages, root, upstreams) when is_list(pages) do
    {parsed, errors} =
      pages
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {page, index}, acc ->
        {page, errors} = page(page, index, root, upstreams)
        {page, acc ++ errors}
      end)

    {Enum.reject(parsed, &is_nil/1), errors}
  end

  defp pages(_pages, _root, _upstreams),
    do: {[], ["page must be an array of tables ([[page]])"]}

  defp page(page, index, root, upstreams) when is_map(page) do
    ctx = "page ##{index}"
    {fields, errors} = TomlSchema.fields(page, ctx, @page_fields)

    errors =
      errors ++
        file_errors(fields.path, root, ctx) ++
        for upstream <- fields.uses || [], upstream not in upstreams do
          ~s(#{ctx}: upstream "#{upstream}" is not allowed for this configuration)
        end

    case errors do
      [] -> {struct!(Page, fields), []}
      errors -> {nil, errors}
    end
  end

  defp page(_page, index, _root, _upstreams), do: {nil, ["page ##{index} must be a table"]}

  defp file_errors(nil, _root, _ctx), do: []

  defp file_errors(path, root, ctx) do
    case File.lstat(Path.join(root, path)) do
      {:ok, %File.Stat{type: :regular}} -> []
      {:ok, %File.Stat{}} -> [~s(#{ctx}.path "#{path}" is not a regular file)]
      {:error, _reason} -> [~s(#{ctx}.path "#{path}" does not exist)]
    end
  end
end
