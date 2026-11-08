defmodule Deepsplay.Catalog do
  @moduledoc """
  What the page catalog shows for a configuration (ADR 17): its current
  revision, rotation, pages with their documentation and parameters, helpers,
  upstreams declared in the manifest (ADR 19), its shared state (ADR 21), and
  all warnings.
  """

  alias Deepsplay.Backends
  alias Deepsplay.HelperIndex
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.PageDoc
  alias Deepsplay.PageParams
  alias Deepsplay.Pages
  alias Deepsplay.Revisions
  alias Deepsplay.Screen.Override
  alias Deepsplay.State
  alias Deepsplay.TimeWindow

  @type param_row :: %{
          param: PageDoc.Param.t(),
          origin: :page | {:helper, String.t()},
          value: String.t() | nil,
          value_origin: String.t() | nil
        }

  @type page :: %{
          path: String.t(),
          doc: PageDoc.t() | nil,
          kind: :page | :fragment | :undocumented,
          params: [param_row()],
          warnings: [String.t()]
        }

  @type rotation_entry :: %{
          path: String.t(),
          query: String.t() | nil,
          duration: pos_integer(),
          weight: float(),
          description: String.t() | nil,
          glob: String.t() | nil,
          windows: String.t() | nil,
          active: boolean(),
          params: [{String.t(), String.t(), String.t()}]
        }

  @type t :: %{
          config: Config.t(),
          current: Revisions.current(),
          rotation: [rotation_entry()],
          pages: [page()],
          helpers: [map()],
          upstreams: [map()],
          overrides: [map()],
          disabled: [map()],
          backend: map() | nil,
          state: map() | nil,
          warnings: [String.t()]
        }

  @doc """
  The catalog of a configuration, from its current revision.
  """
  @spec for_config(Config.t()) :: {:ok, t()} | :none | {:error, [String.t()]}
  def for_config(%Config{} = config) do
    with {:ok, current} <- Revisions.current(config) do
      context = Revisions.param_context(config, current)
      index = Pages.index(current.pages_dir, current.sha)
      pages = Enum.map(Pages.files(current.pages_dir, current.sha), &page(context, index, &1))

      {:ok,
       %{
         config: config,
         current: current,
         rotation: rotation(context, current),
         pages: Enum.sort_by(pages, &{kind_order(&1.kind), &1.path}),
         helpers: helpers(index, pages),
         upstreams: upstreams(current.screen),
         overrides: overrides(current.screen),
         disabled: disabled(current.screen),
         backend: backend(config, current.screen),
         state: state(config),
         warnings: warnings(current, index, pages)
       }}
    end
  end

  defp page(context, index, path) do
    case Pages.doc(context.pages_dir, context.key, path) do
      {:ok, doc} ->
        {params, collisions} = HelperIndex.params_for(doc, index)
        {added, added_warnings, _declared} = PageParams.explain(context, path, nil, nil)
        added = Map.new(added, fn {name, value, origin} -> {name, {value, origin}} end)

        rows =
          params
          |> Enum.sort_by(fn {name, {_param, origin}} -> {origin != :page, name} end)
          |> Enum.map(fn {name, {param, origin}} ->
            {value, value_origin} = Map.get(added, name, {nil, nil})
            %{param: param, origin: origin, value: value, value_origin: value_origin}
          end)

        %{
          path: path,
          doc: doc,
          kind: if(doc.page, do: :page, else: :fragment),
          params: rows,
          warnings: doc.warnings ++ collisions ++ added_warnings
        }

      _undocumented ->
        %{path: path, doc: nil, kind: :undocumented, params: [], warnings: []}
    end
  end

  defp rotation(context, current) do
    current.screen.pages
    |> Enum.zip(current.added)
    |> Enum.map(fn {page, _added} ->
      {explained, _warnings, _declared} =
        PageParams.explain(context, page.path, page.query, page.duration)

      own =
        if page.query,
          do:
            page.query |> URI.query_decoder() |> Enum.map(fn {k, v} -> {k, v, "page query"} end),
          else: []

      %{
        path: page.path,
        query: page.query,
        duration: page.duration,
        weight: page.weight,
        description: page.description,
        glob: page.glob,
        windows: page.when && TimeWindow.describe_all(page.when),
        active: TimeWindow.active?(page.when, now()),
        params: own ++ explained
      }
    end)
  end

  defp helpers(index, pages) do
    index.helpers
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn helper ->
      used_by =
        for %{doc: %PageDoc{uses: uses}, path: path} <- pages, helper.name in uses, do: path

      Map.put(helper, :used_by, used_by)
    end)
  end

  # Overrides (ADR 25) with their windows and whether they are active now,
  # in the server's local time (screens use their own).
  defp overrides(screen) do
    for override <- screen.overrides do
      %{
        path: override.path,
        query: override.query,
        windows: TimeWindow.describe_all(override.when),
        priority: override.priority,
        description: override.description,
        active: TimeWindow.active?(override.when, now())
      }
    end
  end

  # Entries switched off with `enabled = false` (ADR 29).
  defp disabled(screen) do
    for entry <- screen.disabled do
      %{
        kind: if(match?(%Override{}, entry), do: :override, else: :page),
        what: entry_name(entry),
        description: entry.description
      }
    end
  end

  defp entry_name(%{glob: glob}) when is_binary(glob), do: glob
  defp entry_name(%{path: path, query: nil}), do: path
  defp entry_name(%{path: path, query: query}), do: path <> "?" <> query

  defp now, do: NaiveDateTime.local_now()

  # The backend (ADR 26) and the state of its process.
  defp backend(_config, %{backend: nil}), do: nil

  defp backend(config, %{backend: spec}) do
    state =
      case Backends.all()[config.name] do
        %{info: info} -> info.state
        nil -> :not_running
      end

    %{spec: spec, state: state}
  end

  # Upstreams declared in the manifest (ADR 19), with the rotation pages
  # listing them.
  defp upstreams(screen) do
    screen.upstreams
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn upstream ->
      used_by = for page <- screen.pages, upstream.name in page.uses, uniq: true, do: page.path
      %{upstream: upstream, used_by: used_by}
    end)
  end

  # The namespace with its first keys and shortened values, or nil without
  # shared state.
  @state_keys 100
  @value_chars 120

  defp state(config) do
    with {:ok, host_config} <- Store.get(),
         namespace when is_binary(namespace) <- State.namespace(host_config, config) do
      keys = State.list(namespace)

      entries =
        for {key, version} <- Enum.take(keys, @state_keys),
            {:ok, json, _version} <- [State.get(namespace, key)] do
          %{key: key, version: version, value: shorten(json)}
        end

      %{namespace: namespace, entries: entries, total: length(keys)}
    else
      _none -> nil
    end
  end

  defp shorten(json) do
    if String.length(json) > @value_chars,
      do: String.slice(json, 0, @value_chars) <> "…",
      else: json
  end

  defp warnings(current, index, pages) do
    page_warnings =
      for %{path: path, warnings: warnings} <- pages,
          warning <- warnings,
          do: "#{path}: #{warning}"

    helper_warnings =
      for helper <- Map.values(index.helpers),
          warning <- helper.warnings,
          do: "#{helper.file}: #{warning}"

    Enum.uniq(
      current.screen.warnings ++
        current.param_warnings ++ index.warnings ++ helper_warnings ++ page_warnings
    )
  end

  defp kind_order(:page), do: 0
  defp kind_order(:undocumented), do: 1
  defp kind_order(:fragment), do: 2
end
