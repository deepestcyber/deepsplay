defmodule DeepsplayWeb.ShellRotationTest do
  # Not async: uses the global host configuration.
  use DeepsplayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Deepsplay.ScreenFixture

  alias Deepsplay.GitFixture
  alias Deepsplay.Revisions

  @moduletag :tmp_dir

  @files %{
    "screen.toml" => """
    title    = "Lobby"
    rotation = "random"

    [[page]]
    path     = "welcome.html"
    duration = "30s"
    weight   = 2

    [[page]]
    path     = "news/index.html"
    duration = "10s"
    """,
    "pages/welcome.html" => "welcome",
    "pages/news/index.html" => "news",
    "pages/extra.html" => "not in the rotation"
  }

  setup %{tmp_dir: tmp_dir} do
    setup_screen(tmp_dir, @files)
  end

  defp plan(view) do
    view
    |> element("#screen-rotation")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-plan")
    |> hd()
    |> Jason.decode!()
  end

  test "shows the fallback page until a revision is available", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#fallback-no-revision")
    refute has_element?(view, "#screen-rotation")
  end

  test "the fallback page shows the last error and the next attempt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#fallback-last-error")

    now = DateTime.utc_now()

    Deepsplay.Status.update("lobby", %{
      error: "check failed: unreachable",
      error_at: now,
      next_check_at: DateTime.add(now, 30, :second)
    })

    assert has_element?(view, "#fallback-last-error", "check failed: unreachable")
    assert has_element?(view, "#fallback-next-check")
  end

  test "rotates the pages of the current revision", %{conn: conn, config: config, sha: sha} do
    {:ok, ^sha} = Revisions.refresh(config)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#screen-rotation[phx-hook]")
    assert page_title(view) =~ "Lobby"

    assert plan(view) == %{
             "sha" => sha,
             "mode" => "random",
             "apply" => "next",
             "no_repeat_entries" => 1,
             "no_repeat_pages" => 0,
             "pages" => [
               %{
                 "url" => "/c/lobby/r/#{sha}/welcome.html",
                 "entry" => "welcome.html",
                 "file" => "welcome.html",
                 "duration" => 30_000,
                 "weight" => 2.0,
                 "when" => nil
               },
               %{
                 "url" => "/c/lobby/r/#{sha}/news/index.html",
                 "entry" => "news/index.html",
                 "file" => "news/index.html",
                 "duration" => 10_000,
                 "weight" => 1.0,
                 "when" => nil
               }
             ],
             "overrides" => [],
             "empty" => nil
           }

    assert_push_event(view, "plan", %{sha: ^sha, mode: "random"})
  end

  test "pushes the plan of a new revision", %{conn: conn, config: config, src: src} do
    {:ok, _sha} = Revisions.refresh(config)
    {:ok, view, _html} = live(conn, ~p"/c/lobby")

    new = GitFixture.commit(src, %{"pages/welcome.html" => "welcome v2"})
    {:ok, ^new} = Revisions.refresh(config)

    assert_push_event(view, "plan", %{sha: ^new})
  end

  test "switches from the fallback page to content when a revision arrives",
       %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#fallback-no-revision")

    {:ok, _sha} = Revisions.refresh(config)

    assert render(view) =~ "screen-rotation"
    assert has_element?(view, "#screen-rotation")
  end

  test "?page= pins any file in pages/", %{conn: conn, config: config, sha: sha} do
    {:ok, ^sha} = Revisions.refresh(config)

    {:ok, view, _html} = live(conn, ~p"/?page=extra.html")

    assert plan(view) == %{
             "sha" => sha,
             "mode" => "pinned",
             "apply" => "next",
             "no_repeat_entries" => 0,
             "no_repeat_pages" => 0,
             "pages" => [
               %{
                 "url" => "/c/lobby/r/#{sha}/extra.html",
                 "entry" => "extra.html",
                 "file" => "extra.html",
                 "duration" => nil,
                 "weight" => 1.0,
                 "when" => nil
               }
             ],
             "overrides" => [],
             "empty" => nil
           }
  end

  test "?page= keeps a query string for the pinned page", %{conn: conn, config: config, sha: sha} do
    {:ok, ^sha} = Revisions.refresh(config)

    {:ok, view, _html} = live(conn, ~p"/?#{[page: "extra.html?duration=5s"]}")

    assert %{"pages" => [%{"url" => url}]} = plan(view)
    assert url == "/c/lobby/r/#{sha}/extra.html?duration=5s"
  end

  test "adds declared default parameters to page URLs, pinned too", %{conn: conn, src: src} do
    sha =
      GitFixture.commit(src, %{
        "screen.toml" => """
        duration = "20s"

        [params]
        theme = "neon"

        [[page]]
        path = "themed.html?extra=1"
        """,
        "pages/themed.html" => """
        <script type="application/toml" id="deepsplay-page">
        [params.theme]
        type   = "enum"
        values = ["default", "neon"]
        [params.duration]
        type = "duration"
        from = "duration"
        </script>
        """
      })

    {:ok, ^sha} = Revisions.refresh(Deepsplay.HostConfig.Store.lookup("lobby") |> elem(1))

    {:ok, view, _html} = live(conn, ~p"/")

    assert %{"pages" => [%{"url" => url}]} = plan(view)
    assert url == "/c/lobby/r/#{sha}/themed.html?extra=1&duration=20s&theme=neon"

    {:ok, pinned, _html} = live(build_conn(), ~p"/?page=themed.html")
    assert %{"pages" => [%{"url" => pinned_url}]} = plan(pinned)
    assert pinned_url == "/c/lobby/r/#{sha}/themed.html?theme=neon"
  end

  test "?page= with a missing, hidden or outside file shows the fallback page",
       %{conn: conn, config: config} do
    {:ok, _sha} = Revisions.refresh(config)

    for page <- ["missing.html", "../screen.toml", ".hidden", "news"] do
      {:ok, view, _html} = live(conn, ~p"/?page=#{page}")

      assert has_element?(view, "#fallback-pinned-missing"), page
      assert has_element?(view, "#fallback-page", page)
    end
  end
end
