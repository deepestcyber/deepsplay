defmodule Deepsplay.PageDoc do
  @moduledoc """
  The documentation and parameter definition a page carries in its HTML file
  (ADR 14):

      <script type="application/toml" id="deepsplay-page">
      description = "…"
      [params.cells]
      type    = "int"
      default = 90
      </script>

  The block is found by text search (a `<script>` start tag with both
  `type="application/toml"` and `id="deepsplay-page"`, up to the next
  `</script>`), so no HTML parser is needed. Problems never make a page
  unusable: they are collected as warnings, and the rest is kept.
  """

  alias Deepsplay.PageDoc.Param

  @fields ~w(title description author credits license uses page params variants)

  @max_name 200
  @max_credits 500
  @max_license 100

  defstruct title: nil,
            description: nil,
            authors: [],
            credits: nil,
            license: nil,
            uses: [],
            page: true,
            params: %{},
            variants: [],
            warnings: []

  @type variant :: %{label: String.t(), query: String.t()}

  @type t :: %__MODULE__{
          title: String.t() | nil,
          description: String.t() | nil,
          authors: [String.t()],
          credits: String.t() | nil,
          license: String.t() | nil,
          uses: [String.t()],
          page: boolean(),
          params: %{String.t() => Param.t()},
          variants: [variant()],
          warnings: [String.t()]
        }

  @block ~r{<script\b(?=[^>]*\btype\s*=\s*["']application/toml["'])(?=[^>]*\bid\s*=\s*["']deepsplay-page["'])[^>]*>(.*?)</script\s*>}is

  @doc """
  Reads the documentation of an HTML file. `:none` means the file has no
  block (an undocumented page).
  """
  @spec read(Path.t()) :: {:ok, t()} | :none | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, html} ->
        from_html(html)

      {:error, reason} ->
        {:error, "cannot read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Finds and parses the block in an HTML document.
  """
  @spec from_html(String.t()) :: {:ok, t()} | :none
  def from_html(html) do
    case Regex.run(@block, html, capture: :all_but_first) do
      [toml] -> {:ok, parse(toml, title_tag(html))}
      nil -> :none
    end
  end

  @doc """
  Parses the TOML of a block. `fallback_title` is used without a `title`.
  """
  @spec parse(String.t(), String.t() | nil) :: t()
  def parse(toml, fallback_title \\ nil) do
    case TomlElixir.decode(toml, spec: :"1.0.0") do
      {:ok, data} ->
        build(data, fallback_title)

      {:error, error} ->
        %__MODULE__{
          title: fallback_title,
          warnings: ["invalid TOML: #{Exception.message(error)}"]
        }
    end
  end

  @doc """
  Parses only the parameter definitions of a TOML text, as a helper registers
  them (ADR 15).
  """
  @spec params(String.t()) :: {%{String.t() => Param.t()}, [String.t()]}
  def params(toml) do
    doc = parse(toml)
    {doc.params, doc.warnings}
  end

  defp build(data, fallback_title) do
    {title, w1} = string(data, "title")
    {description, w2} = string(data, "description")
    {uses, w3} = uses(data["uses"])
    {page, w4} = page(data["page"])
    {params, w5} = params_table(data["params"])
    {variants, w6} = variants(data["variants"])
    {authors, w7} = authors(data["author"])
    {credits, w8} = text(data, "credits", @max_credits)
    {license, w9} = text(data, "license", @max_license)

    unknown =
      for key <- Map.keys(data) -- @fields, do: ~s(unknown key "#{key}")

    %__MODULE__{
      title: title || fallback_title,
      description: description,
      authors: authors,
      credits: credits,
      license: license,
      uses: uses,
      page: page,
      params: params,
      variants: variants,
      warnings: w1 ++ w2 ++ w3 ++ w4 ++ w5 ++ w6 ++ w7 ++ w8 ++ w9 ++ Enum.sort(unknown)
    }
  end

  defp string(data, key) do
    case Map.fetch(data, key) do
      :error -> {nil, []}
      {:ok, value} when is_binary(value) -> {value, []}
      {:ok, _value} -> {nil, ["#{key} must be a string"]}
    end
  end

  # Metadata (ADR 24): `author` is a name or a list of names; names are
  # trimmed, empty ones dropped, too long ones dropped with a warning.
  defp authors(nil), do: {[], []}
  defp authors(name) when is_binary(name), do: authors([name])

  defp authors(names) when is_list(names) do
    if Enum.all?(names, &is_binary/1) do
      names
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({[], []}, fn name, {kept, warnings} ->
        if String.length(name) <= @max_name,
          do: {kept ++ [name], warnings},
          else: {kept, warnings ++ ["author names must be at most #{@max_name} characters"]}
      end)
    else
      {[], ["author must be a string or a list of strings"]}
    end
  end

  defp authors(_value), do: {[], ["author must be a string or a list of strings"]}

  defp text(data, key, max) do
    case Map.fetch(data, key) do
      :error ->
        {nil, []}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" ->
            {nil, []}

          text ->
            if String.length(text) <= max,
              do: {text, []},
              else: {nil, ["#{key} must be at most #{max} characters"]}
        end

      {:ok, _value} ->
        {nil, ["#{key} must be a string"]}
    end
  end

  defp uses(nil), do: {[], []}

  defp uses(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {list, []},
      else: {[], ["uses must be a list of strings"]}
  end

  defp uses(_value), do: {[], ["uses must be a list of strings"]}

  defp page(nil), do: {true, []}
  defp page(value) when is_boolean(value), do: {value, []}
  defp page(_value), do: {true, ["page must be true or false"]}

  defp params_table(nil), do: {%{}, []}

  defp params_table(table) when is_map(table) do
    table
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn {name, param_table}, {params, warnings} ->
      case Param.from_table(name, param_table) do
        {nil, w} -> {params, warnings ++ w}
        {param, w} -> {Map.put(params, name, param), warnings ++ w}
      end
    end)
  end

  defp params_table(_value), do: {%{}, ["params must be a table"]}

  defp variants(nil), do: {[], []}

  defp variants(list) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn
      {%{"label" => label, "query" => query} = v, _i}, {acc, w}
      when is_binary(label) and is_binary(query) and map_size(v) == 2 ->
        {acc ++ [%{label: label, query: String.trim_leading(query, "?")}], w}

      {_variant, i}, {acc, w} ->
        {acc, w ++ ["variant ##{i} needs exactly a label and a query (strings)"]}
    end)
  end

  defp variants(_value), do: {[], ["variants must be an array of tables ([[variants]])"]}

  defp title_tag(html) do
    case Regex.run(~r{<title[^>]*>(.*?)</title\s*>}is, html, capture: :all_but_first) do
      [title] -> title |> String.trim() |> decode_entities() |> nil_if_empty()
      nil -> nil
    end
  end

  defp decode_entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(text), do: text
end
