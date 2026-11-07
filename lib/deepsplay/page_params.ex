defmodule Deepsplay.PageParams do
  @moduledoc """
  The parameters deepsplay adds to page URLs (ADR 16).

  For each parameter a page declares (itself, or through a helper in `uses`)
  and does not set in its own query, the first valid value of:

    1. the configuration's `params`,
    2. the manifest's `[params]`,
    3. a value deepsplay provides (`from = "duration"`: the display time).

  The definition's own `default` is applied by the page helper in the browser
  and not added. Values are checked against the definition; invalid ones are
  skipped with a warning. Pages without documentation get nothing.
  """

  alias Deepsplay.HelperIndex
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.PageDoc.Param
  alias Deepsplay.Pages
  alias Deepsplay.Screen

  @type context :: %{
          config: Config.t(),
          screen: Screen.t(),
          pages_dir: Path.t(),
          key: String.t()
        }

  @type added :: [{String.t(), String.t()}]

  @doc """
  The parameters to add to one page: its path relative to `pages/`, its own
  query, and its display time in milliseconds (`nil` for pinned pages).
  Returns the parameters, warnings, and the names the page declares.
  """
  @spec for_page(context(), String.t(), String.t() | nil, pos_integer() | nil) ::
          {added(), [String.t()], [String.t()]}
  def for_page(context, path, query, duration) do
    {explained, warnings, declared} = explain(context, path, query, duration)
    {Enum.map(explained, fn {name, value, _origin} -> {name, value} end), warnings, declared}
  end

  @doc """
  Like `for_page/4`, with the origin of each added value: `"configuration"`,
  `"manifest"` or `"display time"`.
  """
  @spec explain(context(), String.t(), String.t() | nil, pos_integer() | nil) ::
          {[{String.t(), String.t(), String.t()}], [String.t()], [String.t()]}
  def explain(context, path, query, duration) do
    case Pages.doc(context.pages_dir, context.key, path) do
      {:ok, doc} ->
        {params, _collisions} =
          HelperIndex.params_for(doc, Pages.index(context.pages_dir, context.key))

        given = query_names(query)

        {added, warnings} =
          params
          |> Enum.sort()
          |> Enum.reject(fn {name, _} -> name in given end)
          |> Enum.reduce({[], []}, fn {name, {param, _origin}}, {added, warnings} ->
            case pick(context, name, param, duration, path) do
              {nil, w} -> {added, warnings ++ w}
              {{value, origin}, w} -> {added ++ [{name, value, origin}], warnings ++ w}
            end
          end)

        # A fragment in a rotation is likely a mistake (ADR 14).
        fragment =
          if duration && doc.page == false,
            do: [~s(#{path} is marked page = false but is in the rotation)],
            else: []

        {added, warnings ++ fragment, Map.keys(params)}

      _undocumented ->
        {[], [], []}
    end
  end

  @doc """
  The parameters to add to every page of a configuration's rotation, in the
  manifest's order, and warnings: invalid values, and defaults no page of the
  rotation declares.
  """
  @spec for_rotation(context()) :: {[added()], [String.t()]}
  def for_rotation(context) do
    results =
      Enum.map(context.screen.pages, fn page ->
        for_page(context, page.path, page.query, page.duration)
      end)

    declared = results |> Enum.flat_map(fn {_, _, names} -> names end) |> MapSet.new()

    undeclared =
      for {origin, params} <- [
            configuration: context.config.params,
            manifest: context.screen.params
          ],
          name <- params |> Map.keys() |> Enum.sort(),
          name not in declared,
          do: ~s(default parameter "#{name}" from the #{origin} is not declared by any page)

    warnings = Enum.flat_map(results, fn {_, w, _} -> w end) ++ undeclared
    {Enum.map(results, fn {added, _, _} -> added end), Enum.uniq(warnings)}
  end

  @doc """
  The parameters for an override (ADR 25): those added as for a pinned page,
  and the names that get the remaining time of the override's window in the
  browser (`from = "duration"`, unless set otherwise).
  """
  @spec for_override(context(), String.t(), String.t() | nil) :: {added(), [String.t()]}
  def for_override(context, path, query) do
    {added, _warnings, _declared} = for_page(context, path, query, nil)
    # Any display time shows which names it would fill.
    {explained, _warnings, _declared} = explain(context, path, query, 1_000)
    {added, for({name, _value, "display time"} <- explained, do: name)}
  end

  @doc """
  Appends added parameters to a page's own query.
  """
  @spec merge_query(String.t() | nil, added()) :: String.t() | nil
  def merge_query(query, []), do: query
  def merge_query(nil, added), do: URI.encode_query(added)
  def merge_query(query, added), do: query <> "&" <> URI.encode_query(added)

  @doc """
  Writes milliseconds in the duration format of manifests.

      iex> Deepsplay.PageParams.format_duration(30_000)
      "30s"

      iex> Deepsplay.PageParams.format_duration(1_500)
      "1500ms"
  """
  @spec format_duration(pos_integer()) :: String.t()
  def format_duration(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  def format_duration(ms), do: "#{ms}ms"

  # The first valid value in order of precedence.
  defp pick(context, name, param, duration, path) do
    candidates = [
      {"configuration", Map.get(context.config.params, name)},
      {"manifest", Map.get(context.screen.params, name)},
      {"display time", provided(param, duration)}
    ]

    Enum.reduce_while(candidates, {nil, []}, fn
      {_origin, nil}, acc ->
        {:cont, acc}

      {origin, value}, {nil, warnings} ->
        case Param.cast(param, value) do
          {:ok, _typed} ->
            {:halt, {{value, origin}, warnings}}

          :error ->
            warning = ~s(#{origin} value #{name}=#{inspect(value)} is invalid for #{path})
            {:cont, {nil, warnings ++ [warning]}}
        end
    end)
  end

  defp provided(%Param{from: "duration"}, ms) when is_integer(ms), do: format_duration(ms)
  defp provided(_param, _duration), do: nil

  defp query_names(nil), do: []

  defp query_names(query) do
    query |> URI.query_decoder() |> Enum.map(fn {name, _} -> name end)
  end
end
