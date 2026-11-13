defmodule DeepsplayWeb.ScreenPlanTest do
  use ExUnit.Case, async: true

  alias Deepsplay.Screen
  alias Deepsplay.Screen.Page
  alias DeepsplayWeb.ScreenPlan

  doctest ScreenPlan

  test "rotation/3 turns the manifest into a plan" do
    screen = %Screen{
      rotation: :random,
      no_repeat_entries: 2,
      no_repeat_pages: 1,
      pages: [
        %Page{path: "welcome/index.html", duration: 30_000, weight: 3.0},
        %Page{path: "news.html", query: "duration=5s", duration: 5_000}
      ]
    }

    assert ScreenPlan.rotation("lobby", "abc", screen) == %{
             sha: "abc",
             mode: "random",
             apply: "next",
             no_repeat_entries: 2,
             no_repeat_pages: 1,
             pages: [
               %{
                 url: "/c/lobby/r/abc/welcome/index.html",
                 entry: "welcome/index.html",
                 file: "welcome/index.html",
                 duration: 30_000,
                 weight: 3.0,
                 when: nil
               },
               %{
                 url: "/c/lobby/r/abc/news.html?duration=5s",
                 entry: "news.html?duration=5s",
                 file: "news.html",
                 duration: 5_000,
                 weight: 1.0,
                 when: nil
               }
             ],
             overrides: [],
             empty: nil
           }
  end

  test "pinned/3 has a single page without duration" do
    assert ScreenPlan.pinned("lobby", "abc", "a.html") == %{
             sha: "abc",
             mode: "pinned",
             apply: "next",
             no_repeat_entries: 0,
             no_repeat_pages: 0,
             pages: [
               %{
                 url: "/c/lobby/r/abc/a.html",
                 entry: "a.html",
                 file: "a.html",
                 duration: nil,
                 weight: 1.0,
                 when: nil
               }
             ],
             overrides: [],
             empty: nil
           }
  end

  test "rotation/4 carries time windows, overrides and the empty page" do
    {:ok, [window]} = Deepsplay.TimeWindow.parse(%{"from" => "08:00", "until" => "15:00"})

    screen = %Screen{
      pages: [%Page{path: "a.html", duration: 1_000, when: [window]}],
      overrides: [
        %Deepsplay.Screen.Override{path: "drill.html", query: "x=1", when: [window], priority: 3}
      ],
      when_empty: {"idle.html", nil}
    }

    plan =
      ScreenPlan.rotation("lobby", "abc", screen,
        override_added: [{[{"theme", "dark"}], ["duration"]}],
        empty_added: [{"theme", "dark"}]
      )

    assert [%{when: [%{from: 28_800, until: 54_000, days: nil}]}] = plan.pages

    assert plan.overrides == [
             %{
               url: "/c/lobby/r/abc/drill.html?x=1&theme=dark",
               when: [%{start: nil, end: nil, dates: nil, days: nil, from: 28_800, until: 54_000}],
               priority: 3,
               duration_params: ["duration"]
             }
           ]

    assert plan.empty == %{url: "/c/lobby/r/abc/idle.html?theme=dark"}
  end

  test "plans of local directories apply at once" do
    screen = %Screen{pages: [%Page{path: "a.html", duration: 1_000}]}

    assert %{apply: "now"} = ScreenPlan.rotation("lobby", "abc", screen, local: true)
    assert %{apply: "now"} = ScreenPlan.pinned("lobby", "abc", "a.html", nil, local: true)
  end
end
