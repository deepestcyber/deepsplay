defmodule Deepsplay.Screen do
  @moduledoc """
  The manifest of a revision: a TOML file listing pages and how they rotate
  (ADR 5, ADR 9).

  Layout below the root (the repository, or the configured `subdir`):

      screen.toml          default manifest; others are named by `manifest`
      pages/               the only directory that is delivered (ADR 10)

  Page paths in a manifest are relative to `pages/` and may carry a query
  string that is passed on to the page, e.g. `"welcome.html?duration=5s"`.
  Several manifests can list the same pages.

  The manifest is data only. It is validated before a revision is published,
  and a revision that fails is never published.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Upstream
  alias Deepsplay.RevisionFile
  alias Deepsplay.Screen.Page
  alias Deepsplay.Screen.Upstreams
  alias Deepsplay.TomlSchema

  @default_manifest "screen.toml"
  @pages_dir "pages"
  @max_size 64 * 1024

  defstruct title: nil,
            rotation: :sequential,
            pages: [],
            params: %{},
            upstreams: %{},
            warnings: []

  @type t :: %__MODULE__{
          title: String.t() | nil,
          rotation: :sequential | :random,
          pages: [Page.t(), ...],
          params: %{String.t() => String.t()},
          upstreams: %{String.t() => Upstream.t()},
          warnings: [String.t()]
        }

  # Display time of a page that sets none, when the manifest sets none either.
  @default_duration 15_000

  @top_fields [
    {"title", :title, :string, default: nil},
    {"rotation", :rotation, {:enum, ["sequential", "random"]}, default: "sequential"},
    {"duration", :duration, :duration, default: @default_duration}
  ]

  @page_fields [
    {"path", :path, &__MODULE__.cast_page_ref/1, []},
    {"duration", :duration, :duration, default: nil},
    {"weight", :weight, :positive_number, default: 1.0},
    {"uses", :uses, :string_list, default: []}
  ]

  @doc """
  Splits a page reference into the file path and the query string, if any.

      iex> Deepsplay.Screen.split_query("a.html?duration=5s")
      {"a.html", "duration=5s"}

      iex> Deepsplay.Screen.split_query("a.html")
      {"a.html", nil}
  """
  @spec split_query(String.t()) :: {String.t(), String.t() | nil}
  def split_query(ref) do
    case String.split(ref, "?", parts: 2) do
      [path, query] when query != "" -> {path, query}
      [path | _rest] -> {path, nil}
    end
  end

  @doc """
  Returns true if a query string uses only characters allowed in a URL query,
  so it can be passed on unchanged.
  """
  @spec valid_query?(String.t() | nil) :: boolean()
  def valid_query?(nil), do: true
  def valid_query?(query), do: Regex.match?(~r{^[A-Za-z0-9\-._~%!$&'()*+,;=:@/?]+$}, query)

  @doc false
  # Casts a manifest page path with an optional query string.
  def cast_page_ref(value) when is_binary(value) do
    {path, query} = split_query(value)

    with {:ok, path} <- TomlSchema.cast(:relative_path, path) do
      if valid_query?(query),
        do: {:ok, {path, query}},
        else: {:error, "has a query with characters not allowed in a URL"}
    end
  end

  def cast_page_ref(_value), do: {:error, "must be a string"}

  @doc """
  Returns the root for `config` in the revision directory `rev_dir`: the
  revision itself, or its `subdir`.
  """
  @spec root(Path.t(), Config.t()) :: Path.t()
  def root(rev_dir, %Config{subdir: ""}), do: rev_dir
  def root(rev_dir, %Config{subdir: subdir}), do: Path.join(rev_dir, subdir)

  @doc """
  Returns the directory whose files are delivered, below `root`.
  """
  @spec pages_dir(Path.t()) :: Path.t()
  def pages_dir(root), do: Path.join(root, @pages_dir)

  @doc """
  The name of the directory whose files are delivered.
  """
  @spec pages_dir_name() :: String.t()
  def pages_dir_name, do: @pages_dir

  @doc """
  The manifest used when a configuration names none.
  """
  @spec default_manifest() :: String.t()
  def default_manifest, do: @default_manifest

  @doc """
  Options for `load/2` from a configuration.
  """
  @spec options(Config.t()) :: keyword()
  def options(%Config{} = config),
    do: [manifest: config.manifest, upstreams: config.upstreams, config: config]

  @doc """
  Returns a validator for `Deepsplay.RevisionStore.publish/3`: it accepts a
  revision only if its manifest is valid for `config`.
  """
  @spec validator(Config.t()) :: (Path.t() -> :ok | {:error, String.t()})
  def validator(%Config{} = config) do
    fn rev_dir ->
      root = root(rev_dir, config)

      if File.dir?(root) do
        case load(root, options(config)) do
          {:ok, _screen} -> :ok
          {:error, errors} -> {:error, Enum.join(errors, "; ")}
        end
      else
        {:error, ~s(subdir "#{config.subdir}" does not exist)}
      end
    end
  end

  @doc """
  Reads and validates a manifest below `root`.

  Every page `path` must name a deliverable file in `pages/`: a regular file,
  not hidden (see `Deepsplay.RevisionFile.resolve/2`).

  ## Options

    * `:manifest` - manifest path relative to `root`, default
      `"#{@default_manifest}"`
    * `:upstreams` - host upstreams the configuration may use; a page that
      `uses` any other, or one not declared in the manifest, is an error
    * `:config` - the configuration, for its rules on upstreams declared in
      the manifest (ADR 19); without it they are allowed for any host
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def load(root, opts \\ []) do
    manifest = Keyword.get(opts, :manifest, @default_manifest)
    pages_dir = pages_dir(root)

    with {:ok, toml} <- read(Path.join(root, manifest), manifest),
         {:ok, data} <- decode(toml, manifest),
         :ok <- check_pages_dir(pages_dir) do
      config = Keyword.get(opts, :config, %Config{name: "", upstreams: opts[:upstreams] || []})
      build(data, pages_dir, Keyword.get(opts, :upstreams, []), config)
    end
  end

  defp check_pages_dir(pages_dir) do
    case File.lstat(pages_dir) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _other -> {:error, ["#{@pages_dir}/ directory is missing"]}
    end
  end

  defp read(path, name) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_size ->
        {:error, ["#{name} is larger than #{div(@max_size, 1024)} KiB"]}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, toml} ->
            {:ok, toml}

          {:error, reason} ->
            {:error, ["cannot read #{name}: #{:file.format_error(reason)}"]}
        end

      {:ok, %File.Stat{}} ->
        {:error, ["#{name} is not a regular file"]}

      {:error, :enoent} ->
        {:error, ["#{name} is missing"]}

      {:error, reason} ->
        {:error, ["cannot read #{name}: #{:file.format_error(reason)}"]}
    end
  end

  defp decode(toml, name) do
    case TomlElixir.decode(toml) do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, ["#{name} is invalid TOML: #{Exception.message(error)}"]}
    end
  end

  defp build(data, root, upstreams, config) do
    # `page`, `backend`, `params` and `upstream` are read separately;
    # everything else is checked as top-level fields, including unknown keys.
    {top, top_errors} =
      TomlSchema.fields(
        Map.drop(data, ["page", "backend", "params", "upstream"]),
        "screen",
        @top_fields
      )

    {declared, upstream_errors} = Upstreams.parse(Map.get(data, "upstream"), config)

    # Default parameters for the manifest's pages (ADR 16).
    {params, param_errors} =
      case TomlSchema.cast(:params, Map.get(data, "params", %{})) do
        {:ok, params} -> {params, []}
        {:error, why} -> {%{}, ["screen.params #{why}"]}
      end

    # Invalid upstreams still count as declared, so their pages do not report
    # them again.
    names = if is_map(data["upstream"]), do: Map.keys(data["upstream"]), else: []
    {pages, page_errors} = pages(Map.get(data, "page"), root, upstreams ++ names)

    warnings =
      if Map.has_key?(data, "backend"),
        do: ["[backend] is not supported yet and is ignored"],
        else: []

    case top_errors ++ param_errors ++ upstream_errors ++ page_errors do
      [] ->
        {:ok,
         %__MODULE__{
           title: top.title,
           rotation: rotation(top.rotation),
           pages: Enum.map(pages, &%{&1 | duration: &1.duration || top.duration}),
           params: params,
           upstreams: declared,
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

    {path, query} = fields.path || {nil, nil}

    errors =
      errors ++
        file_errors(path, root, ctx) ++
        for upstream <- fields.uses || [], upstream not in upstreams do
          ~s(#{ctx}: upstream "#{upstream}" is not allowed for this configuration)
        end

    case errors do
      [] -> {struct!(Page, %{fields | path: path} |> Map.put(:query, query)), []}
      errors -> {nil, errors}
    end
  end

  defp page(_page, index, _root, _upstreams), do: {nil, ["page ##{index} must be a table"]}

  defp file_errors(nil, _root, _ctx), do: []

  defp file_errors(path, pages_dir, ctx) do
    cond do
      RevisionFile.hidden?(path) ->
        [~s(#{ctx}.path "#{path}" must not name a hidden file or directory)]

      RevisionFile.resolve(pages_dir, path) == :error ->
        [~s(#{ctx}.path "#{path}" is not a file in #{@pages_dir}/)]

      true ->
        []
    end
  end
end
