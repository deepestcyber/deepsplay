defmodule DeepsplayWeb.ScreenPlan do
  @moduledoc """
  The plan a screen rotates through (ADR 9): the revision, the mode, and the
  pages with their URLs, durations and weights. It is sent to the browser,
  which does the rotation.
  """

  alias Deepsplay.Screen

  @type t :: %{
          sha: String.t(),
          mode: String.t(),
          pages: [%{url: String.t(), duration: pos_integer() | nil, weight: float()}]
        }

  @doc """
  Builds the rotation plan for a configuration's revision.
  """
  @spec rotation(String.t(), String.t(), Screen.t()) :: t()
  def rotation(name, sha, %Screen{} = screen) do
    %{
      sha: sha,
      mode: Atom.to_string(screen.rotation),
      pages:
        Enum.map(screen.pages, fn page ->
          %{url: page_url(name, sha, page.path), duration: page.duration, weight: page.weight}
        end)
    }
  end

  @doc """
  Builds the plan for a screen pinned to one file (ADR 11).
  """
  @spec pinned(String.t(), String.t(), String.t()) :: t()
  def pinned(name, sha, path) do
    %{
      sha: sha,
      mode: "pinned",
      pages: [%{url: page_url(name, sha, path), duration: nil, weight: 1.0}]
    }
  end

  @doc """
  Returns the URL of a file in `pages/` of a revision (ADR 10).

      iex> DeepsplayWeb.ScreenPlan.page_url("lobby", "abc", "a b/index.html")
      "/c/lobby/r/abc/a%20b/index.html"
  """
  @spec page_url(String.t(), String.t(), String.t()) :: String.t()
  def page_url(name, sha, path) do
    segments = path |> String.split("/") |> Enum.map_join("/", &encode/1)
    "/c/#{encode(name)}/r/#{sha}/#{segments}"
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
