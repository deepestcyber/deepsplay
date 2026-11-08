defmodule DeepsplayWeb.CatalogLiveTest do
  # Not async: uses the global host configuration.
  use DeepsplayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Deepsplay.ScreenFixture

  alias Deepsplay.GitFixture
  alias Deepsplay.Revisions

  @moduletag :tmp_dir

  @theme """
  const T = Deepsplay.helper("theme", `
  description = "Colours."
  author = "Grace"
  [params.theme]
  type    = "enum"
  values  = ["default", "neon"]
  default = "default"
  [params.duration]
  type = "duration"
  from = "duration"
  `)
  """

  @files %{
    "screen.toml" => """
    title       = "Lobby"
    description = "Day rotation <b>for</b> the lobby."
    duration    = "20s"

    [params]
    theme = "neon"

    [upstream.radar]
    url         = "https://radar.example.com/wms"
    cache_ttl   = "5m"
    refresh     = true
    description = "Rain radar frames"

    [[override]]
    path        = "life.html"
    when        = { start = "2099-01-01" }
    priority    = 2
    description = "New century"

    [[page]]
    path = "life.html?cells=40"
    uses = ["radar"]
    when = { from = "00:00" }
    description = "Large cells for the entrance"

    [[page]]
    path = "fragment.html"
    """,
    "pages/shared/theme.js" => @theme,
    "pages/life.html" => """
    <title>Game of Life</title>
    <script type="application/toml" id="deepsplay-page">
    description = "Cells."
    author = ["Ada", "Grace"]
    credits = "Rules by John Conway"
    license = "MIT"
    uses = ["theme"]
    [params.cells]
    type    = "int"
    default = 90
    min     = 4
    description = "Cells along the shorter side."
    [params.tint]
    type = "color"
    [[variants]]
    label = "Large"
    query = "cells=20"
    </script>
    """,
    "pages/fragment.html" => """
    <script type="application/toml" id="deepsplay-page">
    page = false
    description = "Loaded by life."
    </script>
    """,
    "pages/plain.html" => "<h1>plain</h1>"
  }

  setup %{tmp_dir: tmp_dir} do
    ctx = setup_screen(tmp_dir, @files)
    {:ok, _sha} = Revisions.refresh(ctx.config)
    Deepsplay.State.clear()
    ctx
  end

  test "the overview lists configurations", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/catalog")

    assert has_element?(view, "#catalog-config-lobby", "3 files")
    assert has_element?(view, "#catalog-config-lobby", "2 in rotation")
    assert has_element?(view, "#catalog-config-lobby", "warnings")
  end

  test "the configuration page shows rotation, pages, helpers and warnings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")

    assert has_element?(view, "#catalog-defaults", "theme=neon")

    # Rotation: own query, provided display time, manifest default, each with origin.
    assert has_element?(view, "#rotation-0", "cells=40 (page query)")
    assert has_element?(view, "#rotation-0", "duration=20s (display time)")
    assert has_element?(view, "#rotation-0", "theme=neon (manifest)")

    # Pages: documented first, then undocumented, then fragments.
    assert has_element?(view, "#page-life-html", "Game of Life")
    assert has_element?(view, "#page-life-html", "Cells along the shorter side.")
    assert has_element?(view, "#page-life-html", "theme")
    assert has_element?(view, "#page-plain-html", "undocumented")
    assert has_element?(view, "#page-fragment-html", "not a page")
    refute has_element?(view, "#page-fragment-html .page-preview")

    # Overview: name, file and first line of the description, with links.
    assert has_element?(
             view,
             ~s(#overview-page-life-html a[href="#page-life-html"]),
             "Game of Life"
           )

    assert has_element?(view, "#overview-page-life-html .overview-description", "Cells.")
    assert has_element?(view, "#overview-page-life-html .overview-playground")
    assert has_element?(view, "#overview-page-plain-html", "undocumented")
    refute has_element?(view, "#overview-page-fragment-html .overview-preview")

    # Parameters are collapsed.
    assert has_element?(
             view,
             "#page-life-html details.page-params:not([open]) summary",
             "parameters"
           )

    assert has_element?(view, "#helper-theme", "Used by: life.html")
    assert has_element?(view, "#helper-theme .page-authors", "by Grace")

    assert has_element?(view, "#page-life-html .page-authors", "by Ada, Grace")
    assert has_element?(view, "#page-life-html .page-credits", "Rules by John Conway")
    assert has_element?(view, "#page-life-html .page-license", "MIT")
    refute has_element?(view, "#page-plain-html .page-authors")

    assert has_element?(view, "#upstream-radar", "https://radar.example.com/wms")
    assert has_element?(view, "#upstream-radar", "cache 300s")
    assert has_element?(view, "#upstream-radar", "refresh")
    assert has_element?(view, "#upstream-radar", "Used by: life.html")

    assert has_element?(view, "#catalog-state", "No values.")

    # Descriptions, shown as text.
    assert has_element?(
             view,
             "#catalog-manifest-description",
             "Day rotation <b>for</b> the lobby."
           )

    refute has_element?(view, "#catalog-manifest-description b")
    assert has_element?(view, "#rotation-0 .rotation-description", "Large cells for the entrance")
    assert has_element?(view, "#upstream-radar", "Rain radar frames")

    # Time windows and overrides (ADR 25).
    assert has_element?(view, "#rotation-0 .rotation-windows", "from 00:00")
    assert has_element?(view, "#rotation-0 .rotation-windows", "active now")
    assert has_element?(view, "#override-0", "New century")
    assert has_element?(view, "#override-0", "start 2099-01-01 · priority 2")
    assert has_element?(view, "#override-0", "not active now")
    assert has_element?(view, "#catalog-header", "when nothing is active: black screen")
  end

  test "an override gets added parameters and the remaining time", ctx do
    {:ok, current} = Revisions.current(ctx.config)

    # life.html uses the theme helper: theme from the manifest, duration from
    # the window's remaining time in the browser.
    assert current.override_added == [{[{"theme", "neon"}], ["duration"]}]
  end

  test "the configuration page shows shared state, shortened", %{conn: conn} = ctx do
    {:ok, host_config} = Deepsplay.HostConfig.Store.get()
    namespace = Deepsplay.State.namespace(host_config, ctx.config)
    {:ok, _} = Deepsplay.State.put(namespace, "life/gen", ~s({"n": 7}))

    {:ok, _} =
      Deepsplay.State.put(namespace, "shared/long", Jason.encode!(String.duplicate("x", 500)))

    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")

    assert has_element?(view, "#catalog-state", namespace)
    assert has_element?(view, "#catalog-state .state-entry", ~s({"n":7}))
    assert has_element?(view, "#catalog-state .state-entry", "…")

    assert has_element?(
             view,
             "#catalog-warnings .catalog-warning",
             "fragment.html is marked page = false but is in the rotation"
           )
  end

  test "preview renders the page with added parameters, one at a time", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")
    refute has_element?(view, "#catalog-preview")

    view |> element("#page-life-html .page-variant", "Large") |> render_click()

    assert has_element?(view, "#page-life-html #catalog-preview")

    assert has_element?(
             view,
             ~s(#preview-iframe[src="/c/lobby/r/#{ctx.sha}/life.html?cells=20&theme=neon"])
           )

    assert has_element?(view, "#preview-pin", "page=life.html%3Fcells%3D20")

    view |> element("#page-plain-html .page-preview") |> render_click()
    refute has_element?(view, "#page-life-html #catalog-preview")
    assert has_element?(view, "#page-plain-html #catalog-preview")

    # From the overview.
    view |> element("#overview-page-life-html .overview-preview") |> render_click()
    assert has_element?(view, "#page-life-html #catalog-preview")
  end

  test "the size selector shows custom fields only when chosen", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")
    view |> element("#page-life-html .page-preview") |> render_click()

    refute has_element?(view, "#preview-size input[name=width]")
    assert has_element?(view, ~s(#preview-frame[data-width="1920"][data-height="1080"]))

    view |> form("#preview-size", %{size: "1080x1920"}) |> render_change()
    assert has_element?(view, ~s(#preview-frame[data-width="1080"][data-height="1920"]))

    view |> form("#preview-size", %{size: "custom"}) |> render_change()
    assert has_element?(view, "#preview-size input[name=width]")

    view
    |> form("#preview-size", %{size: "custom", width: "800", height: "600"})
    |> render_change()

    assert has_element?(view, ~s(#preview-frame[data-width="800"][data-height="600"]))
  end

  test "the playground builds the query from the form", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")
    view |> element("#page-life-html .page-playground") |> render_click()

    assert has_element?(view, "#playground-form select[name='p[theme]']")
    assert has_element?(view, "#playground-form input[name='p[cells]'][type=number][min='4']")
    assert has_element?(view, "#playground-form input[name='p[tint]'][type=color]")

    view
    |> form("#playground-form", %{
      p: %{"cells" => "12", "theme" => "", "tint" => "#000000", "duration" => ""}
    })
    |> render_change()

    assert has_element?(
             view,
             ~s(#preview-iframe[src="/c/lobby/r/#{ctx.sha}/life.html?cells=12&theme=neon"])
           )

    view
    |> form("#playground-form", %{
      p: %{"cells" => "12", "theme" => "default", "tint" => "#ff0000", "duration" => "5s"}
    })
    |> render_change()

    assert has_element?(
             view,
             ~s(#preview-iframe[src="/c/lobby/r/#{ctx.sha}/life.html?cells=12&tint=%23ff0000&duration=5s&theme=default"])
           )
  end

  test "updates when a new revision arrives", %{conn: conn} = ctx do
    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")
    refute has_element?(view, "#page-new-html")

    GitFixture.commit(ctx.src, %{"pages/new.html" => "<h1>new</h1>"})
    {:ok, _sha} = Revisions.refresh(ctx.config)

    assert has_element?(view, "#page-new-html")
  end

  test "an unknown configuration says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/catalog/nowhere")
    assert has_element?(view, "#catalog-unknown-config")
  end
end
