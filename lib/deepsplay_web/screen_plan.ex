defmodule DeepsplayWeb.ScreenPlan do
  @moduledoc """
  The plan a screen rotates through (ADR 9): the revision, the mode, and the
  pages with their URLs, durations, weights and time windows; the overrides
  with their windows and priorities; and the page shown when no page is
  active (`empty`, `nil` for a black screen; ADR 25). It is sent to the
  browser, which does the rotation. Time windows are in the form of
  `Deepsplay.TimeWindow.to_plan/1`.

  `apply` says when the browser switches to a new plan: `"next"` at the next
  page change, `"now"` at once, reloading the current page (local directories
  in development, ADR 12).
  """

  alias Deepsplay.PageParams
  alias Deepsplay.Screen
  alias Deepsplay.TimeWindow

  @type t :: %{
          sha: String.t(),
          mode: String.t(),
          apply: String.t(),
          no_repeat_entries: non_neg_integer(),
          no_repeat_pages: non_neg_integer(),
          pages: [
            %{
              url: String.t(),
              entry: String.t(),
              file: String.t(),
              duration: pos_integer() | nil,
              weight: float(),
              when: [map()] | nil
            }
          ],
          overrides: [
            %{url: String.t(), when: [map()], priority: integer(), duration_params: [String.t()]}
          ],
          empty: %{url: String.t()} | nil
        }

  @doc """
  Builds the rotation plan for a configuration's revision.
  """
  #
  # Options: `:local` (apply at once), `:added` (parameters to add to each
  # page, in the manifest's order; ADR 16), `:override_added` (parameters
  # and remaining-time names per override), `:empty_added` (parameters for
  # the `when_empty` page).
  @spec rotation(String.t(), String.t(), Screen.t(), keyword()) :: t()
  def rotation(name, sha, %Screen{} = screen, opts \\ []) do
    added = Keyword.get(opts, :added, Enum.map(screen.pages, fn _ -> [] end))

    %{
      sha: sha,
      mode: Atom.to_string(screen.rotation),
      apply: apply_mode(opts),
      no_repeat_entries: screen.no_repeat_entries,
      no_repeat_pages: screen.no_repeat_pages,
      pages:
        screen.pages
        |> Enum.zip(added)
        |> Enum.map(fn {page, page_added} ->
          %{
            url: page_url(name, sha, page.path, PageParams.merge_query(page.query, page_added)),
            entry: if(page.query, do: page.path <> "?" <> page.query, else: page.path),
            file: page.path,
            duration: page.duration,
            weight: page.weight,
            when: TimeWindow.to_plan(page.when)
          }
        end),
      overrides: overrides(name, sha, screen, opts),
      empty: empty(name, sha, screen, opts)
    }
  end

  defp overrides(name, sha, screen, opts) do
    added = Keyword.get(opts, :override_added, Enum.map(screen.overrides, fn _ -> {[], []} end))

    screen.overrides
    |> Enum.zip(added)
    |> Enum.map(fn {override, {override_added, duration_params}} ->
      %{
        url:
          page_url(
            name,
            sha,
            override.path,
            PageParams.merge_query(override.query, override_added)
          ),
        when: TimeWindow.to_plan(override.when),
        priority: override.priority,
        duration_params: duration_params
      }
    end)
  end

  defp empty(_name, _sha, %Screen{when_empty: :black}, _opts), do: nil

  defp empty(name, sha, %Screen{when_empty: {path, query}}, opts) do
    %{
      url:
        page_url(
          name,
          sha,
          path,
          PageParams.merge_query(query, Keyword.get(opts, :empty_added, []))
        )
    }
  end

  @doc """
  Builds the plan for a screen pinned to one file (ADR 11), with an optional
  query string passed on to the page.
  """
  @spec pinned(String.t(), String.t(), String.t(), String.t() | nil, keyword()) :: t()
  def pinned(name, sha, path, query \\ nil, opts \\ []) do
    %{
      sha: sha,
      mode: "pinned",
      apply: apply_mode(opts),
      no_repeat_entries: 0,
      no_repeat_pages: 0,
      pages: [
        %{
          url: page_url(name, sha, path, query),
          entry: if(query, do: path <> "?" <> query, else: path),
          file: path,
          duration: nil,
          weight: 1.0,
          when: nil
        }
      ],
      overrides: [],
      empty: nil
    }
  end

  @doc """
  Returns the URL of a file in `pages/` of a revision (ADR 10). A query string
  is appended unchanged.

      iex> DeepsplayWeb.ScreenPlan.page_url("lobby", "abc", "a b/index.html")
      "/c/lobby/r/abc/a%20b/index.html"

      iex> DeepsplayWeb.ScreenPlan.page_url("lobby", "abc", "a.html", "duration=5s")
      "/c/lobby/r/abc/a.html?duration=5s"
  """
  @spec page_url(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def page_url(name, sha, path, query \\ nil) do
    segments = path |> String.split("/") |> Enum.map_join("/", &encode/1)
    url = "/c/#{encode(name)}/r/#{sha}/#{segments}"
    if query, do: url <> "?" <> query, else: url
  end

  defp apply_mode(opts), do: if(Keyword.get(opts, :local, false), do: "now", else: "next")

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
