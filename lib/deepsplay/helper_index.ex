defmodule Deepsplay.HelperIndex do
  @moduledoc """
  The shared helpers of a content repository and their parameter definitions
  (ADR 15), found in the JavaScript files below `pages/`.

  A helper registers itself with

      const P = Deepsplay.helper("theme", `
      [params.theme]
      type = "enum"
      …
      `)

  and is found by text search for `Deepsplay.helper("<name>", ` followed by
  a template literal (the TOML must not contain a backtick). Files are read in
  sorted path order; if two helpers register the same name, the first one
  counts.
  """

  alias Deepsplay.PageDoc
  alias Deepsplay.PageDoc.Param

  @registration ~r/Deepsplay\.helper\(\s*(["'])([^"'\n]+)\1\s*,\s*`([^`]*)`/

  @type helper :: %{
          name: String.t(),
          file: String.t(),
          description: String.t() | nil,
          params: %{String.t() => Param.t()},
          warnings: [String.t()]
        }

  @type t :: %{helpers: %{String.t() => helper()}, warnings: [String.t()]}

  @doc """
  Builds the index for a `pages/` directory. File paths in the result are
  relative to it.
  """
  @spec build(Path.t()) :: t()
  def build(pages_dir) do
    pages_dir
    |> script_files()
    |> Enum.flat_map(fn file -> registrations(pages_dir, file) end)
    |> Enum.reduce(%{helpers: %{}, warnings: []}, &add/2)
  end

  @doc """
  The parameters that apply to a page: its own, plus those of the helpers it
  uses, each with its origin (`:page` or `{:helper, name}`), and warnings for
  unknown helpers and collisions (the page wins over a helper, an earlier
  helper in `uses` over a later one).
  """
  @spec params_for(PageDoc.t(), t()) ::
          {%{String.t() => {Param.t(), :page | {:helper, String.t()}}}, [String.t()]}
  def params_for(%PageDoc{} = doc, index) do
    own = Map.new(doc.params, fn {name, param} -> {name, {param, :page}} end)

    Enum.reduce(doc.uses, {own, []}, fn helper_name, {params, warnings} ->
      case Map.fetch(index.helpers, helper_name) do
        {:ok, helper} -> merge_helper(params, warnings, helper)
        :error -> {params, warnings ++ [~s(uses unknown helper "#{helper_name}")]}
      end
    end)
  end

  defp merge_helper(params, warnings, helper) do
    helper.params
    |> Enum.sort()
    |> Enum.reduce({params, warnings}, fn {name, param}, {acc, w} ->
      case Map.fetch(acc, name) do
        :error ->
          {Map.put(acc, name, {param, {:helper, helper.name}}), w}

        {:ok, {_param, :page}} ->
          {acc,
           w ++ [~s(parameter "#{name}" of helper "#{helper.name}" is replaced by the page's)]}

        {:ok, {_param, {:helper, other}}} ->
          {acc,
           w ++
             [~s(parameter "#{name}" of helper "#{helper.name}" is replaced by helper "#{other}")]}
      end
    end)
  end

  defp script_files(pages_dir) do
    ["**/*.js", "**/*.mjs"]
    |> Enum.flat_map(&Path.wildcard(Path.join(pages_dir, &1)))
    |> Enum.filter(&regular?/1)
    |> Enum.sort()
  end

  # Wildcards skip hidden files; symlinks are not followed (ADR 6).
  defp regular?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp registrations(pages_dir, file) do
    relative = Path.relative_to(file, pages_dir)

    case File.read(file) do
      {:ok, source} ->
        for [_, _quote, name, toml] <- Regex.scan(@registration, source) do
          doc = PageDoc.parse(toml)

          %{
            name: name,
            file: relative,
            description: doc.description,
            params: doc.params,
            warnings: doc.warnings
          }
        end

      {:error, _reason} ->
        []
    end
  end

  defp add(helper, index) do
    case Map.fetch(index.helpers, helper.name) do
      :error ->
        %{index | helpers: Map.put(index.helpers, helper.name, helper)}

      {:ok, first} ->
        warning =
          ~s(helper "#{helper.name}" in #{helper.file} is ignored; #{first.file} registers it first)

        %{index | warnings: index.warnings ++ [warning]}
    end
  end
end
