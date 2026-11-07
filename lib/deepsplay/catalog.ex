defmodule Deepsplay.Catalog do
  @moduledoc """
  What the page catalog shows for a configuration (ADR 17): its current
  revision, rotation, pages with their documentation and parameters, helpers,
  upstreams declared in the manifest (ADR 19), and all warnings.
  """

  alias Deepsplay.HelperIndex
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.PageDoc
  alias Deepsplay.PageParams
  alias Deepsplay.Pages
  alias Deepsplay.Revisions

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
          params: [{String.t(), String.t(), String.t()}]
        }

  @type t :: %{
          config: Config.t(),
          current: Revisions.current(),
          rotation: [rotation_entry()],
          pages: [page()],
          helpers: [map()],
          upstreams: [map()],
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
