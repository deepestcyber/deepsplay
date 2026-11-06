defmodule DeepsplayWeb.ScreenPlanTest do
  use ExUnit.Case, async: true

  alias Deepsplay.Screen
  alias Deepsplay.Screen.Page
  alias DeepsplayWeb.ScreenPlan

  doctest ScreenPlan

  test "rotation/3 turns the manifest into a plan" do
    screen = %Screen{
      rotation: :random,
      pages: [
        %Page{path: "welcome/index.html", duration: 30_000, weight: 3.0},
        %Page{path: "news.html", query: "duration=5s", duration: 5_000}
      ]
    }

    assert ScreenPlan.rotation("lobby", "abc", screen) == %{
             sha: "abc",
             mode: "random",
             pages: [
               %{url: "/c/lobby/r/abc/welcome/index.html", duration: 30_000, weight: 3.0},
               %{url: "/c/lobby/r/abc/news.html?duration=5s", duration: 5_000, weight: 1.0}
             ]
           }
  end

  test "pinned/3 has a single page without duration" do
    assert ScreenPlan.pinned("lobby", "abc", "a.html") == %{
             sha: "abc",
             mode: "pinned",
             pages: [%{url: "/c/lobby/r/abc/a.html", duration: nil, weight: 1.0}]
           }
  end
end
