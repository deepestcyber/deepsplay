defmodule Deepsplay.Screen do
  @moduledoc """
  The manifest of a revision: a TOML file listing pages and how they rotate
  (ADR 5, ADR 9).

  Layout below the root (the repository, or the configured `subdir`):

      screen.toml          default manifest; others are named by `manifest`
      pages/               the only directory that is delivered (ADR 10)

  Page paths in a manifest are relative to `pages/` and may carry a query
  string that is passed on to the page, e.g. `"welcome.html?duration=5s"`.
  A page entry can name its pages with `glob` instead (ADR 28); each page
  found becomes an entry of its own. Several manifests can list the same
  pages.

  The manifest is data only. It is validated before a revision is published,
  and a revision that fails is never published.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.HostConfig.Upstream
  alias Deepsplay.PageDoc
  alias Deepsplay.RevisionFile
  alias Deepsplay.Screen.Backend
  alias Deepsplay.Screen.Glob
  alias Deepsplay.Screen.Interrupt
  alias Deepsplay.Screen.Override
  alias Deepsplay.Screen.Page
  alias Deepsplay.Screen.Upstreams
  alias Deepsplay.TimeWindow
  alias Deepsplay.TomlSchema

  @default_manifest "screen.toml"
  @pages_dir "pages"
  @max_size 64 * 1024

  defstruct title: nil,
            description: nil,
            rotation: :sequential,
            pages: [],
            params: %{},
            upstreams: %{},
            overrides: [],
            interrupts: [],
            when_empty: :black,
            backend: nil,
            disabled: [],
            warnings: []

  @type t :: %__MODULE__{
          title: String.t() | nil,
          description: String.t() | nil,
          rotation: :sequential | :random,
          pages: [Page.t()],
          params: %{String.t() => String.t()},
          upstreams: %{String.t() => Upstream.t()},
          overrides: [Override.t()],
          interrupts: [Interrupt.t()],
          when_empty: :black | {String.t(), String.t() | nil},
          backend: Backend.t() | nil,
          disabled: [Page.t() | Override.t() | Interrupt.t()],
          warnings: [String.t()]
        }

  # Display time of a page that sets none, when the manifest sets none either.
  @default_duration 15_000

  @top_fields [
    {"title", :title, :string, default: nil},
    {"description", :description, :description, default: nil},
    {"rotation", :rotation, {:enum, ["sequential", "random"]}, default: "sequential"},
    {"duration", :duration, :duration, default: @default_duration},
    {"when_empty", :when_empty, &__MODULE__.cast_when_empty/1, default: :black}
  ]

  @page_fields [
    {"path", :path, &__MODULE__.cast_page_ref/1, []},
    {"duration", :duration, :duration, default: nil},
    {"weight", :weight, :positive_number, default: 1.0},
    {"uses", :uses, :string_list, default: []},
    {"description", :description, :description, default: nil},
    {"when", :when, &__MODULE__.cast_when/1, default: nil},
    {"enabled", :enabled, :boolean, default: true}
  ]

  # An entry naming its pages by pattern (ADR 28).
  @glob_fields [
    {"glob", :glob, :string, []},
    {"exclude", :exclude, &__MODULE__.cast_patterns/1, default: []},
    {"query", :query, &__MODULE__.cast_query/1, default: nil}
    | tl(@page_fields)
  ]

  @override_fields [
    {"path", :path, &__MODULE__.cast_page_ref/1, []},
    {"when", :when, &__MODULE__.cast_when/1, []},
    {"priority", :priority, &__MODULE__.cast_priority/1, default: 0},
    {"description", :description, :description, default: nil},
    {"uses", :uses, :string_list, default: []},
    {"enabled", :enabled, :boolean, default: true}
  ]

  # Pages put on all screens when triggered (ADR 32).
  @interrupt_fields [
    {"name", :name, &__MODULE__.cast_interrupt_name/1, []},
    {"path", :path, &__MODULE__.cast_page_ref/1, []},
    {"duration", :duration, :duration, []},
    {"priority", :priority, &__MODULE__.cast_priority/1, default: 0},
    {"description", :description, :description, default: nil},
    {"uses", :uses, :string_list, default: []},
    {"enabled", :enabled, :boolean, default: true}
  ]

  @doc false
  def cast_when(value) do
    case TimeWindow.parse(value) do
      {:ok, windows} -> {:ok, windows}
      {:error, message} -> {:error, message}
    end
  end

  @doc false
  def cast_when_empty("black"), do: {:ok, :black}
  def cast_when_empty(value) when is_binary(value), do: cast_page_ref(value)
  def cast_when_empty(_value), do: {:error, ~s(must be "black" or a page path)}

  @doc false
  def cast_patterns(value) when is_binary(value), do: {:ok, [value]}

  def cast_patterns(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {:ok, value},
      else: {:error, "must be a string or a list of strings"}
  end

  def cast_patterns(_value), do: {:error, "must be a string or a list of strings"}

  @doc false
  def cast_query(value) when is_binary(value) do
    cond do
      value == "" -> {:ok, nil}
      valid_query?(value) -> {:ok, value}
      true -> {:error, "has characters not allowed in a URL"}
    end
  end

  def cast_query(_value), do: {:error, "must be a string"}

  @doc false
  def cast_priority(value) when is_integer(value), do: {:ok, value}
  def cast_priority(_value), do: {:error, "must be an integer"}

  @doc false
  # Interrupt names end up in trigger URLs (ADR 32).
  def cast_interrupt_name(value) when is_binary(value) do
    if byte_size(value) <= 64 and Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, value),
      do: {:ok, value},
      else: {:error, ~s(must be lowercase letters, digits, "-" and "_", at most 64 characters)}
  end

  def cast_interrupt_name(_value), do: {:error, "must be a string"}

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
  def options(%Config{} = config) do
    max_cache_size =
      case Store.get() do
        {:ok, host_config} -> host_config.upstream_cache_size
        {:error, _errors} -> nil
      end

    [
      manifest: config.manifest,
      upstreams: config.upstreams,
      config: config,
      max_cache_size: max_cache_size
    ]
  end

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
    * `:max_cache_size` - the host's `upstream_cache_size`, the most a
      manifest upstream's `cache_size` may be (ADR 22)
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def load(root, opts \\ []) do
    manifest = Keyword.get(opts, :manifest, @default_manifest)
    pages_dir = pages_dir(root)

    with {:ok, toml} <- read(Path.join(root, manifest), manifest),
         {:ok, data} <- decode(toml, manifest),
         :ok <- check_pages_dir(pages_dir) do
      config = Keyword.get(opts, :config, %Config{name: "", upstreams: opts[:upstreams] || []})
      build(data, pages_dir, Keyword.get(opts, :upstreams, []), config, opts[:max_cache_size])
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

  defp build(data, root, upstreams, config, max_cache_size) do
    # `page`, `backend`, `params` and `upstream` are read separately;
    # everything else is checked as top-level fields, including unknown keys.
    {top, top_errors} =
      TomlSchema.fields(
        Map.drop(data, ["page", "backend", "params", "upstream", "override", "interrupt"]),
        "screen",
        @top_fields
      )

    {declared, upstream_errors} =
      Upstreams.parse(Map.get(data, "upstream"), config, max_cache_size)

    # Default parameters for the manifest's pages (ADR 16).
    {params, param_errors} =
      case TomlSchema.cast(:params, Map.get(data, "params", %{})) do
        {:ok, params} -> {params, []}
        {:error, why} -> {%{}, ["screen.params #{why}"]}
      end

    # Invalid upstreams still count as declared, so their pages do not report
    # them again.
    names = if is_map(data["upstream"]), do: Map.keys(data["upstream"]), else: []
    {pages, page_errors, page_warnings} = pages(Map.get(data, "page"), root, upstreams ++ names)
    {overrides, override_errors} = overrides(Map.get(data, "override"), root, upstreams ++ names)

    {interrupts, interrupt_errors} =
      interrupts(Map.get(data, "interrupt"), root, upstreams ++ names)

    when_empty_errors =
      case top.when_empty do
        {path, _query} -> file_errors(path, root, "screen.when_empty")
        _black_or_invalid -> []
      end

    # The pages directory's parent is the root (manifests, backend dir).
    {backend, backend_errors, warnings} =
      Backend.parse(Map.get(data, "backend"), Path.dirname(root), config)

    case top_errors ++
           param_errors ++
           upstream_errors ++
           page_errors ++
           override_errors ++ interrupt_errors ++ when_empty_errors ++ backend_errors do
      [] ->
        with_duration = &%{&1 | duration: &1.duration || top.duration}
        {pages, disabled_pages} = Enum.split_with(pages, & &1.enabled)
        {overrides, disabled_overrides} = Enum.split_with(overrides, & &1.enabled)
        {interrupts, disabled_interrupts} = Enum.split_with(interrupts, & &1.enabled)

        {:ok,
         %__MODULE__{
           title: top.title,
           description: top.description,
           rotation: rotation(top.rotation),
           pages: Enum.map(pages, with_duration),
           params: params,
           upstreams: declared,
           overrides: overrides,
           interrupts: interrupts,
           when_empty: top.when_empty,
           backend: backend,
           disabled:
             Enum.map(disabled_pages, with_duration) ++ disabled_overrides ++ disabled_interrupts,
           warnings: page_warnings ++ warnings ++ interrupt_warnings(interrupts, backend, config)
         }}

      errors ->
        {:error, errors}
    end
  end

  defp rotation("sequential"), do: :sequential
  defp rotation("random"), do: :random

  defp pages(nil, _root, _upstreams), do: {[], ["at least one [[page]] is required"], []}
  defp pages([], _root, _upstreams), do: {[], ["at least one [[page]] is required"], []}

  defp pages(entries, root, upstreams) when is_list(entries) do
    {parsed, {errors, warnings}} =
      entries
      |> Enum.with_index(1)
      |> Enum.map_reduce({[], []}, fn {entry, index}, {errors, warnings} ->
        {parsed, e, w} = page(entry, index, root, upstreams)
        {parsed, {errors ++ e, warnings ++ w}}
      end)

    parsed = Enum.reject(parsed, &is_nil/1)

    # Files with an entry of their own are left out of patterns (ADR 28),
    # also when that entry is disabled (ADR 29).
    explicit = for %Page{} = page <- parsed, into: MapSet.new(), do: page.path

    files =
      if Enum.any?(parsed, &match?({:glob, %Page{enabled: true}, _, _}, &1)),
        do: html_files(root),
        else: []

    {pages, glob_warnings} =
      Enum.flat_map_reduce(parsed, [], fn
        %Page{} = page, acc ->
          {[page], acc}

        # A disabled glob entry finds nothing; it is kept to be listed (ADR 29).
        {:glob, %Page{enabled: false} = page, _excludes, _ctx}, acc ->
          {[page], acc}

        {:glob, page, excludes, ctx}, acc ->
          {found, w} = expand(page, excludes, ctx, files, explicit, root)
          {found, acc ++ w}
      end)

    {pages, errors, warnings ++ glob_warnings}
  end

  defp pages(_pages, _root, _upstreams),
    do: {[], ["page must be an array of tables ([[page]])"], []}

  defp page(page, index, root, upstreams) when is_map(page) do
    ctx = "page ##{index}"

    case {Map.has_key?(page, "path"), Map.has_key?(page, "glob")} do
      {true, true} ->
        warning = "#{ctx} has both path and glob; glob, exclude and query are ignored"
        {parsed, errors, warnings} = path_page(page, ctx, root, upstreams)
        {parsed, errors, [warning | warnings]}

      {false, true} ->
        glob_page(page, ctx, upstreams)

      _path_or_none ->
        path_page(page, ctx, root, upstreams)
    end
  end

  defp page(_page, index, _root, _upstreams), do: {nil, ["page ##{index} must be a table"], []}

  defp path_page(page, ctx, root, upstreams) do
    ignored = Enum.filter(["exclude", "query"], &Map.has_key?(page, &1))

    warnings =
      for key <- ignored,
          not Map.has_key?(page, "glob"),
          do: "#{ctx}: #{key} is only used with glob and is ignored"

    page = Map.drop(page, ["glob" | ignored])
    {fields, errors} = TomlSchema.fields(page, ctx, @page_fields)
    {path, query} = fields.path || {nil, nil}
    errors = errors ++ file_errors(path, root, ctx) ++ uses_errors(fields.uses, upstreams, ctx)

    case errors do
      [] -> {struct!(Page, %{fields | path: path} |> Map.put(:query, query)), [], warnings}
      errors -> {nil, errors, warnings}
    end
  end

  defp glob_page(page, ctx, upstreams) do
    {fields, errors} = TomlSchema.fields(page, ctx, @glob_fields)
    errors = errors ++ uses_errors(fields.uses, upstreams, ctx)

    case errors do
      [] ->
        {excludes, fields} = Map.pop(fields, :exclude)
        # `path` is set per page found.
        page = struct!(Page, fields |> Map.put(:path, nil))
        {{:glob, page, excludes, ctx}, [], []}

      errors ->
        {nil, errors, []}
    end
  end

  defp uses_errors(uses, upstreams, ctx) do
    for upstream <- uses || [], upstream not in upstreams do
      ~s(#{ctx}: upstream "#{upstream}" is not allowed for this configuration)
    end
  end

  # The pages a glob entry finds, in alphabetical order, and warnings.
  defp expand(page, excludes, ctx, files, explicit, root) do
    with {:ok, glob} <- compile(page.glob, "#{ctx}.glob"),
         {:ok, excludes} <- compile_all(excludes, "#{ctx}.exclude") do
      matched = Enum.filter(files, &Glob.match?(glob, &1))

      unused =
        for {pattern, exclude} <- excludes,
            not Enum.any?(matched, &Glob.match?(exclude, &1)),
            do: ~s(#{ctx}.exclude "#{pattern}" matches no page of the glob)

      found =
        matched
        |> Enum.reject(fn path ->
          Enum.any?(excludes, fn {_, ex} -> Glob.match?(ex, path) end)
        end)
        |> Enum.reject(&MapSet.member?(explicit, &1))
        |> Enum.reject(&fragment?(root, &1))

      empty = if found == [], do: [~s(#{ctx}.glob "#{page.glob}" matches no page)], else: []
      {Enum.map(found, &%{page | path: &1}), empty ++ unused}
    else
      {:error, warning} -> {[], [warning]}
    end
  end

  defp compile(pattern, ctx) do
    case Glob.compile(pattern) do
      {:ok, glob} -> {:ok, glob}
      {:error, why} -> {:error, ~s(#{ctx} "#{pattern}" #{why}; the entry is ignored)}
    end
  end

  defp compile_all(patterns, ctx) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case compile(pattern, ctx) do
        {:ok, glob} -> {:cont, {:ok, acc ++ [{pattern, glob}]}}
        error -> {:halt, error}
      end
    end)
  end

  # Deliverable `.html` files below `pages/`, relative to it and sorted.
  defp html_files(pages_dir) do
    pages_dir
    |> Path.join("**/*.html")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, pages_dir))
    |> Enum.filter(&match?({:ok, _}, RevisionFile.resolve(pages_dir, &1)))
    |> Enum.sort()
  end

  # Files marked `page = false` (ADR 14) are not pages of their own.
  defp fragment?(pages_dir, path) do
    with {:ok, file} <- RevisionFile.resolve(pages_dir, path),
         {:ok, %PageDoc{page: false}} <- PageDoc.read(file) do
      true
    else
      _page -> false
    end
  end

  defp overrides(nil, _root, _upstreams), do: {[], []}

  defp overrides(entries, root, upstreams) when is_list(entries) do
    {parsed, errors} =
      entries
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {entry, index}, acc ->
        {override, errors} = override(entry, index, root, upstreams)
        {override, acc ++ errors}
      end)

    {Enum.reject(parsed, &is_nil/1), errors}
  end

  defp overrides(_entries, _root, _upstreams),
    do: {[], ["override must be an array of tables ([[override]])"]}

  defp override(entry, index, root, upstreams) when is_map(entry) do
    ctx = "override ##{index}"
    {fields, errors} = TomlSchema.fields(entry, ctx, @override_fields)
    {path, query} = fields.path || {nil, nil}

    errors =
      errors ++
        file_errors(path, root, ctx) ++
        for upstream <- fields.uses || [], upstream not in upstreams do
          ~s(#{ctx}: upstream "#{upstream}" is not allowed for this configuration)
        end

    case errors do
      [] -> {struct!(Override, %{fields | path: path} |> Map.put(:query, query)), []}
      errors -> {nil, errors}
    end
  end

  defp override(_entry, index, _root, _upstreams),
    do: {nil, ["override ##{index} must be a table"]}

  # Interrupts need someone who may trigger them (ADR 32, ADR 33).
  defp interrupt_warnings([], _backend, _config), do: []

  defp interrupt_warnings(_interrupts, backend, %Config{interrupt_token: token, mqtt_topic: topic})
       when backend != nil or token != nil or topic != nil,
       do: []

  defp interrupt_warnings(_interrupts, _backend, _config),
    do: [
      "[[interrupt]] cannot be triggered: the configuration has no backend, " <>
        "no interrupt_token and no mqtt_topic"
    ]

  defp interrupts(nil, _root, _upstreams), do: {[], []}

  defp interrupts(entries, root, upstreams) when is_list(entries) do
    {parsed, errors} =
      entries
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {entry, index}, acc ->
        {interrupt, errors} = interrupt(entry, index, root, upstreams)
        {interrupt, acc ++ errors}
      end)

    parsed = Enum.reject(parsed, &is_nil/1)

    # Names are unique, also among disabled ones: a trigger names one.
    duplicates =
      for {name, [_, _ | _]} <- Enum.group_by(parsed, & &1.name),
          do: ~s(interrupt "#{name}" is defined more than once)

    {parsed, errors ++ Enum.sort(duplicates)}
  end

  defp interrupts(_entries, _root, _upstreams),
    do: {[], ["interrupt must be an array of tables ([[interrupt]])"]}

  defp interrupt(entry, index, root, upstreams) when is_map(entry) do
    ctx = "interrupt ##{index}"
    {fields, errors} = TomlSchema.fields(entry, ctx, @interrupt_fields)
    {path, query} = fields.path || {nil, nil}
    errors = errors ++ file_errors(path, root, ctx) ++ uses_errors(fields.uses, upstreams, ctx)

    case errors do
      [] -> {struct!(Interrupt, %{fields | path: path} |> Map.put(:query, query)), []}
      errors -> {nil, errors}
    end
  end

  defp interrupt(_entry, index, _root, _upstreams),
    do: {nil, ["interrupt ##{index} must be a table"]}

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
