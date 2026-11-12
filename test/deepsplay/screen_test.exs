defmodule Deepsplay.ScreenTest do
  use ExUnit.Case, async: true

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.RevisionStore
  alias Deepsplay.Screen
  alias Deepsplay.Screen.Interrupt
  alias Deepsplay.Screen.Override
  alias Deepsplay.Screen.Page

  @moduletag :tmp_dir

  doctest Screen

  @one_page ~s([[page]]\npath = "a.html"\nduration = "1s"\n)

  defp write(root, files) do
    for {path, content} <- files do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    root
  end

  defp errors(root, opts \\ []) do
    assert {:error, errors} = Screen.load(root, opts)
    errors
  end

  describe "load/2 with a valid manifest" do
    test "reads title, rotation and pages relative to pages/", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        title    = "Lobby"
        rotation = "random"

        [[page]]
        path     = "welcome/index.html"
        duration = "30s"
        weight   = 3

        [[page]]
        path     = "weather/index.html"
        duration = "45s"
        weight   = 0.5
        uses     = ["weather"]
        """,
        "pages/welcome/index.html" => "w",
        "pages/weather/index.html" => "x"
      })

      assert {:ok, screen} = Screen.load(root, upstreams: ["weather"])

      assert %Screen{title: "Lobby", rotation: :random, warnings: []} = screen

      assert screen.pages == [
               %Page{path: "welcome/index.html", duration: 30_000, weight: 3.0, uses: []},
               %Page{path: "weather/index.html", duration: 45_000, weight: 0.5, uses: ["weather"]}
             ]
    end

    test "reads descriptions of the manifest and its page entries", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        title       = "Lobby"
        description = "What the lobby shows during the day."

        [[page]]
        path        = "a.html?cells=200"
        description = "Fast version for the hall"

        [[page]]
        path = "a.html"
        """,
        "pages/a.html" => "a"
      })

      assert {:ok, screen} = Screen.load(root)
      assert screen.description == "What the lobby shows during the day."
      assert [%{description: "Fast version for the hall"}, %{description: nil}] = screen.pages
    end

    test "applies defaults", %{tmp_dir: root} do
      write(root, %{"screen.toml" => @one_page, "pages/a.html" => "a"})

      assert {:ok, %Screen{title: nil, rotation: :sequential, pages: [page]}} = Screen.load(root)
      assert page.weight == 1.0
      assert page.uses == []
    end

    test "passes a query string in a page path on, checking only the file", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => ~s([[page]]\npath = "a.html?duration=5s&x=1"\nduration = "5s"\n),
        "pages/a.html" => "a"
      })

      assert {:ok, %Screen{pages: [%Page{path: "a.html", query: "duration=5s&x=1"}]}} =
               Screen.load(root)
    end

    test "uses the manifest duration for pages without their own", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        duration = "30s"

        [[page]]
        path = "a.html"

        [[page]]
        path     = "b.html"
        duration = "5s"
        """,
        "pages/a.html" => "a",
        "pages/b.html" => "b"
      })

      assert {:ok, %Screen{pages: [%Page{duration: 30_000}, %Page{duration: 5_000}]}} =
               Screen.load(root)
    end

    test "reads default parameters", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => ~s([params]\ntheme = "neon"\ncells = 40\n\n) <> @one_page,
        "pages/a.html" => "a"
      })

      assert {:ok, %Screen{params: %{"theme" => "neon", "cells" => "40"}}} = Screen.load(root)

      write(root, %{"screen.toml" => ~s(params = "theme=neon"\n) <> @one_page})
      assert ["screen.params must be a table of parameter values"] = errors(root)
    end

    test "falls back to 15 seconds without any duration", %{tmp_dir: root} do
      write(root, %{"screen.toml" => ~s([[page]]\npath = "a.html"\n), "pages/a.html" => "a"})
      assert {:ok, %Screen{pages: [%Page{duration: 15_000}]}} = Screen.load(root)
    end

    test "reads another manifest, sharing the same pages", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => @one_page,
        "rotations/kitchen.toml" => ~s(rotation = "random"\n) <> @one_page,
        "pages/a.html" => "a"
      })

      assert {:ok, %Screen{rotation: :sequential}} = Screen.load(root)

      assert {:ok, %Screen{rotation: :random, pages: [%Page{path: "a.html"}]}} =
               Screen.load(root, manifest: "rotations/kitchen.toml")
    end

    test "ignores a [backend] table with a warning unless backends are allowed",
         %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => ~s([backend]\ncommand = "x"\n) <> @one_page,
        "pages/a.html" => "a"
      })

      assert {:ok, %Screen{backend: nil, warnings: [warning]}} = Screen.load(root)
      assert warning == "[backend] is ignored: backends are not allowed for this configuration"
    end
  end

  describe "load/2 rejects" do
    test "a missing manifest, named in the message", %{tmp_dir: root} do
      assert errors(root) == ["screen.toml is missing"]

      assert errors(root, manifest: "rotations/kitchen.toml") == [
               "rotations/kitchen.toml is missing"
             ]
    end

    test "a missing pages/ directory", %{tmp_dir: root} do
      write(root, %{"screen.toml" => @one_page, "a.html" => "a"})
      assert errors(root) == ["pages/ directory is missing"]
    end

    test "a manifest that is too large", %{tmp_dir: root} do
      write(root, %{"screen.toml" => "# " <> String.duplicate("x", 70_000)})
      assert [error] = errors(root)
      assert error =~ "larger than 64 KiB"
    end

    test "invalid TOML", %{tmp_dir: root} do
      write(root, %{"screen.toml" => "[[page"})
      assert [error] = errors(root)
      assert error =~ "screen.toml is invalid TOML"
    end

    test "a manifest without pages", %{tmp_dir: root} do
      write(root, %{"screen.toml" => ~s(title = "Empty"\n), "pages/a.html" => "a"})
      assert errors(root) == ["at least one [[page]] is required"]
    end

    test "unknown keys and invalid values", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        rotation = "shuffle"
        colour   = "red"

        [[page]]
        path     = "a.html"
        duration = "often"
        weight   = 0
        wieght   = 2
        """,
        "pages/a.html" => "a"
      })

      errors = errors(root)

      assert ~s(screen.rotation must be one of: "sequential", "random") in errors
      assert ~s(screen: unknown key "colour") in errors
      assert Enum.any?(errors, &(&1 =~ "page #1.duration must be a duration"))
      assert "page #1.weight must be a number greater than 0" in errors
      assert ~s(page #1: unknown key "wieght") in errors
    end

    test "a page without path", %{tmp_dir: root} do
      write(root, %{"screen.toml" => "[[page]]\n", "pages/a.html" => "a"})
      assert errors(root) == ["page #1.path is missing"]
    end

    test "an invalid manifest duration", %{tmp_dir: root} do
      write(root, %{"screen.toml" => ~s(duration = "soon"\n) <> @one_page, "pages/a.html" => "a"})
      assert [error] = errors(root)
      assert error =~ "screen.duration must be a duration"
    end

    test "paths that are not deliverable files in pages/", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        [[page]]
        path = "../README.md"
        duration = "1s"

        [[page]]
        path = "/etc/passwd"
        duration = "1s"

        [[page]]
        path = "missing.html"
        duration = "1s"

        [[page]]
        path = "dir"
        duration = "1s"

        [[page]]
        path = ".hidden/a.html"
        duration = "1s"
        """,
        "README.md" => "outside pages/",
        "pages/dir/index.html" => "x",
        "pages/.hidden/a.html" => "x"
      })

      errors = errors(root)

      assert ~s(page #1.path must not contain "..") in errors
      assert "page #2.path must be a relative path" in errors
      assert ~s(page #3.path "missing.html" is not a file in pages/) in errors
      assert ~s(page #4.path "dir" is not a file in pages/) in errors

      assert ~s(page #5.path ".hidden/a.html" must not name a hidden file or directory) in errors
    end

    test "a query string on a missing file, or with characters not allowed in a URL",
         %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        [[page]]
        path = "missing.html?duration=5s"
        duration = "1s"

        [[page]]
        path = "a.html?text=two words"
        duration = "1s"
        """,
        "pages/a.html" => "a"
      })

      assert errors(root) == [
               ~s(page #1.path "missing.html" is not a file in pages/),
               "page #2.path has a query with characters not allowed in a URL"
             ]
    end

    test "upstreams the configuration does not allow", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          ~s([[page]]\npath = "a.html"\nduration = "1s"\nuses = ["weather", "news"]\n),
        "pages/a.html" => "a"
      })

      assert errors(root, upstreams: ["weather"]) == [
               ~s(page #1: upstream "news" is not allowed for this configuration)
             ]
    end
  end

  describe "load/2 with glob entries" do
    @small %{
      "pages/small/a.html" => "a",
      "pages/small/b.html" => "b",
      "pages/small/draft-c.html" => "c",
      "pages/small/old.html" => "old",
      "pages/small/deep/d.html" => "d",
      "pages/small/style.css" => "css",
      "pages/small/.hidden.html" => "hidden",
      "pages/small/part.html" => """
      <script type="application/toml" id="deepsplay-page">
      page = false
      </script>
      """,
      "pages/main.html" => "main"
    }

    test "each page found becomes an entry, in place and in order", %{tmp_dir: root} do
      write(
        root,
        Map.put(@small, "screen.toml", """
        [[page]]
        path = "main.html"

        [[page]]
        glob     = "small/*.html"
        exclude  = ["small/draft-*.html", "small/old.html"]
        query    = "theme=neon"
        duration = "20s"
        weight   = 0.5
        when     = { from = "08:00" }

        [[page]]
        path = "small/b.html?big=1"
        """)
      )

      assert {:ok, screen} = Screen.load(root)
      assert screen.warnings == []

      # b.html has an entry of its own; part.html is a fragment; deep/ needs **.
      assert [
               %Page{path: "main.html", glob: nil},
               %Page{path: "small/a.html", glob: "small/*.html"} = a,
               %Page{path: "small/b.html", query: "big=1", glob: nil}
             ] = screen.pages

      assert %{query: "theme=neon", duration: 20_000, weight: 0.5} = a
      assert [%{}] = a.when
    end

    test "** matches across directories, {a,b} alternatives", %{tmp_dir: root} do
      write(
        root,
        Map.put(@small, "screen.toml", """
        [[page]]
        glob    = "small/**"
        exclude = "small/{draft-*,old}.html"
        """)
      )

      assert {:ok, screen} = Screen.load(root)

      assert Enum.map(screen.pages, & &1.path) ==
               ["small/a.html", "small/b.html", "small/deep/d.html"]

      # The manifest's default duration applies.
      assert Enum.all?(screen.pages, &(&1.duration == 15_000))
    end

    test "a page matched by two globs appears twice", %{tmp_dir: root} do
      write(
        root,
        Map.put(@small, "screen.toml", """
        [[page]]
        glob = "small/a.html"

        [[page]]
        glob = "small/{a,b}.html"
        """)
      )

      assert {:ok, screen} = Screen.load(root)
      assert Enum.map(screen.pages, & &1.path) == ["small/a.html", "small/a.html", "small/b.html"]
    end

    test "problems are warnings and never stop the revision", %{tmp_dir: root} do
      write(
        root,
        Map.put(@small, "screen.toml", """
        [[page]]
        path = "main.html"
        glob = "small/*.html"

        [[page]]
        path    = "main.html"
        exclude = "x.html"
        query   = "a=1"

        [[page]]
        glob = "../secret/*.html"

        [[page]]
        glob = "nothing/*.html"

        [[page]]
        glob    = "small/a.html"
        exclude = "small/zzz.html"
        """)
      )

      assert {:ok, screen} = Screen.load(root)
      assert Enum.map(screen.pages, & &1.path) == ["main.html", "main.html", "small/a.html"]

      assert screen.warnings == [
               "page #1 has both path and glob; glob, exclude and query are ignored",
               "page #2: exclude is only used with glob and is ignored",
               "page #2: query is only used with glob and is ignored",
               ~s(page #3.glob "../secret/*.html" must not leave pages/ (..\); the entry is ignored),
               ~s(page #4.glob "nothing/*.html" matches no page),
               ~s(page #5.exclude "small/zzz.html" matches no page of the glob)
             ]
    end

    test "a glob that finds nothing leaves an empty rotation", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        [[page]]
        glob = "*.html"
        """,
        "pages/style.css" => "css"
      })

      assert {:ok, %Screen{pages: [], warnings: [_warning]}} = Screen.load(root)
    end

    test "invalid types are errors", %{tmp_dir: root} do
      write(
        root,
        Map.put(@small, "screen.toml", """
        [[page]]
        glob    = 1
        exclude = [2]
        query   = "a b"
        """)
      )

      assert errors(root) == [
               "page #1.glob must be a non-empty string",
               "page #1.exclude must be a string or a list of strings",
               "page #1.query has characters not allowed in a URL"
             ]
    end
  end

  describe "load/2 with disabled entries" do
    test "disabled entries are validated and kept apart", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        [[page]]
        path = "a.html"

        [[page]]
        path    = "b.html?x=1"
        enabled = false

        [[page]]
        glob    = "*.html"

        [[page]]
        glob    = "nothing/*.html"
        enabled = false

        [[override]]
        path    = "a.html"
        when    = { from = "10:00" }
        enabled = false
        """,
        "pages/a.html" => "a",
        "pages/b.html" => "b",
        "pages/c.html" => "c"
      })

      assert {:ok, screen} = Screen.load(root)

      # b.html is kept out of the glob by its disabled entry; the disabled
      # glob reports no warning.
      assert Enum.map(screen.pages, & &1.path) == ["a.html", "c.html"]
      assert screen.overrides == []
      assert screen.warnings == []

      assert [
               %Page{path: "b.html", query: "x=1", enabled: false, duration: 15_000},
               %Page{path: nil, glob: "nothing/*.html", enabled: false},
               %Override{path: "a.html", enabled: false}
             ] = screen.disabled
    end

    test "a disabled entry must still be valid", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        [[page]]
        path = "a.html"

        [[page]]
        path    = "gone.html"
        enabled = false

        [[page]]
        path    = "a.html"
        enabled = "no"
        """,
        "pages/a.html" => "a"
      })

      assert errors(root) == [
               ~s(page #2.path "gone.html" is not a file in pages/),
               "page #3.enabled must be true or false"
             ]
    end
  end

  describe "load/2 with time windows and overrides" do
    test "reads windows, when_empty and overrides", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        when_empty = "idle.html?dim=1"

        [[page]]
        path = "a.html"
        when = { from = "08:00", until = "15:00" }

        [[page]]
        path = "a.html"

        [[override]]
        path        = "drill.html"
        when        = { start = "2027-03-04 10:00", end = "2027-03-04 10:15" }
        priority    = 10
        description = "Fire drill"

        [[override]]
        path = "a.html?lunch=1"
        when = [{ days = "mon-fri", from = "11:45", until = "12:00" }]
        """,
        "pages/a.html" => "a",
        "pages/idle.html" => "idle",
        "pages/drill.html" => "drill"
      })

      assert {:ok, screen} = Screen.load(root)
      assert [%{when: [%{from: 28_800, until: 54_000}]}, %{when: nil}] = screen.pages
      assert screen.when_empty == {"idle.html", "dim=1"}

      assert [drill, lunch] = screen.overrides
      assert {drill.path, drill.priority, drill.description} == {"drill.html", 10, "Fire drill"}
      assert {lunch.path, lunch.query, lunch.priority} == {"a.html", "lunch=1", 0}
      assert [%{days: [1, 2, 3, 4, 5]}] = lunch.when
    end

    test "defaults: black when empty, no overrides", %{tmp_dir: root} do
      write(root, %{"screen.toml" => @one_page, "pages/a.html" => "a"})
      assert {:ok, %{when_empty: :black, overrides: []}} = Screen.load(root)
    end

    test "invalid windows, when_empty and overrides", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        when_empty = "missing.html"

        [[page]]
        path = "a.html"
        when = { from = "8:00" }

        [[override]]
        path = "a.html"

        [[override]]
        path     = "gone.html"
        when     = { from = "08:00" }
        priority = "high"
        uses     = ["nope"]
        """,
        "pages/a.html" => "a"
      })

      assert errors(root) == [
               ~s[page #1.when from must be "HH:MM" or "HH:MM:SS" (24-hour)],
               "override #1.when is missing",
               "override #2.priority must be an integer",
               ~s(override #2.path "gone.html" is not a file in pages/),
               ~s(override #2: upstream "nope" is not allowed for this configuration),
               ~s(screen.when_empty.path "missing.html" is not a file in pages/)
             ]
    end
  end

  describe "load/2 with interrupts" do
    test "reads interrupts with defaults", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        [[page]]
        path = "a.html"

        [[interrupt]]
        name        = "doorbell"
        path        = "bell.html?loud=1"
        duration    = "30s"
        priority    = 20
        description = "Someone at the door"
        uses        = ["weather"]

        [[interrupt]]
        name     = "build_broken-2"
        path     = "a.html"
        duration = "1m"
        """,
        "pages/a.html" => "a",
        "pages/bell.html" => "bell"
      })

      assert {:ok, screen} = Screen.load(root, upstreams: ["weather"])

      assert [
               %Interrupt{
                 name: "doorbell",
                 path: "bell.html",
                 query: "loud=1",
                 duration: 30_000,
                 priority: 20,
                 description: "Someone at the door",
                 uses: ["weather"],
                 enabled: true
               },
               %Interrupt{name: "build_broken-2", query: nil, duration: 60_000, priority: 0}
             ] = screen.interrupts
    end

    test "a warning when nobody can trigger them", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          @one_page <>
            """

            [[interrupt]]
            name     = "doorbell"
            path     = "a.html"
            duration = "30s"
            """,
        "pages/a.html" => "a"
      })

      assert {:ok, screen} = Screen.load(root)

      assert screen.warnings == [
               "[[interrupt]] cannot be triggered: the configuration has no backend, " <>
                 "no interrupt_token and no mqtt_topic"
             ]

      config = %Config{name: "lobby", interrupt_token: "trigger"}
      assert {:ok, %{warnings: []}} = Screen.load(root, config: config)

      config = %Config{name: "lobby", mqtt_topic: "deepcyber/lobby/+"}
      assert {:ok, %{warnings: []}} = Screen.load(root, config: config)
    end

    test "none by default", %{tmp_dir: root} do
      write(root, %{"screen.toml" => @one_page, "pages/a.html" => "a"})
      assert {:ok, %{interrupts: []}} = Screen.load(root)
    end

    test "disabled interrupts are kept apart", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          @one_page <>
            """

            [[interrupt]]
            name     = "doorbell"
            path     = "a.html"
            duration = "30s"
            enabled  = false
            """,
        "pages/a.html" => "a"
      })

      assert {:ok, screen} = Screen.load(root)
      assert screen.interrupts == []
      assert [%Interrupt{name: "doorbell", enabled: false}] = screen.disabled
    end

    test "invalid entries reject the manifest", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          @one_page <>
            """

            [[interrupt]]
            path = "a.html"

            [[interrupt]]
            name     = "Door Bell"
            path     = "gone.html"
            duration = "soon"
            priority = "high"
            uses     = ["nope"]

            [[interrupt]]
            name     = "#{String.duplicate("a", 65)}"
            path     = "a.html"
            duration = "5s"
            colour   = "red"
            """,
        "pages/a.html" => "a"
      })

      assert [
               "interrupt #1.name is missing",
               "interrupt #1.duration is missing",
               "interrupt #2.name " <> _,
               "interrupt #2.duration " <> _,
               "interrupt #2.priority must be an integer",
               ~s(interrupt #2.path "gone.html" is not a file in pages/),
               ~s(interrupt #2: upstream "nope" is not allowed for this configuration),
               "interrupt #3.name " <> _,
               "interrupt #3" <> unknown
             ] = errors(root)

      assert unknown =~ "colour"
    end

    test "names are unique, also among disabled ones", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          @one_page <>
            """

            [[interrupt]]
            name     = "doorbell"
            path     = "a.html"
            duration = "30s"

            [[interrupt]]
            name     = "doorbell"
            path     = "a.html"
            duration = "10s"
            enabled  = false
            """,
        "pages/a.html" => "a"
      })

      assert errors(root) == [~s(interrupt "doorbell" is defined more than once)]
    end

    test "must be an array of tables", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => ~s(interrupt = "doorbell"\n) <> @one_page,
        "pages/a.html" => "a"
      })

      assert errors(root) == ["interrupt must be an array of tables ([[interrupt]])"]
    end
  end

  describe "load/2 with a backend" do
    defp backend_config(fields \\ []),
      do: struct!(%Config{name: "lobby", backend: true, backend_secrets: ["weather_api"]}, fields)

    test "reads it for configurations that allow backends", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          """
          [backend]
          dir     = "backend"
          command = ["uvicorn", "app:app", "--port", "{port}"]
          health  = "/health"
          secrets = ["weather_api"]
          """ <> @one_page,
        "backend/pyproject.toml" => "[project]",
        "backend/uv.lock" => "",
        "pages/a.html" => "a"
      })

      assert {:ok, screen} = Screen.load(root, config: backend_config())
      assert screen.warnings == []

      assert screen.backend == %Deepsplay.Screen.Backend{
               dir: "backend",
               command: ["uvicorn", "app:app", "--port", "{port}"],
               health: "/health",
               secrets: ["weather_api"]
             }
    end

    test "refuses invalid backends", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          """
          [backend]
          dir     = "pages/py"
          command = "uvicorn app:app"
          health  = "health"
          secrets = ["other"]
          start   = "lazy"
          """ <> @one_page,
        "pages/a.html" => "a",
        "pages/py/pyproject.toml" => ""
      })

      assert errors(root, config: backend_config()) == [
               ~s(backend.command must be a list of strings, e.g. ["uvicorn", "app:app"]),
               ~s(backend.health must be a path starting with "/"),
               ~s(backend: unknown key "start"),
               ~s(backend.dir "pages/py" must not be inside pages/),
               ~s(backend: secret "other" is not allowed for this configuration)
             ]
    end

    test "needs pyproject.toml and uv.lock", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          ~s([backend]\ndir = "backend"\ncommand = ["python", "app.py"]\n) <> @one_page,
        "backend/app.py" => "",
        "pages/a.html" => "a"
      })

      assert errors(root, config: backend_config()) == [
               ~s(backend.dir "backend" has no pyproject.toml),
               ~s(backend.dir "backend" has no uv.lock)
             ]

      other = Path.join(root, "other")

      write(other, %{
        "screen.toml" => ~s([backend]\ndir = "py"\ncommand = ["x"]\n) <> @one_page,
        "pages/a.html" => "a"
      })

      assert errors(other, config: backend_config()) == [~s(backend.dir "py" is not a directory)]
    end
  end

  describe "load/2 with upstreams in the manifest" do
    @radar """
    [upstream.radar]
    url       = "https://maps.dwd.de/geoserver/dwd/wms/"
    cache_ttl = "5m"
    stale_ttl = "1h"
    refresh   = true
    accepted_types = ["image/png"]
    cache_size = "20MB"
    description = "DWD rain radar frames"

    [[page]]
    path = "a.html"
    uses = ["radar"]
    """

    defp lobby(fields \\ []), do: struct!(%Config{name: "lobby", upstreams: ["weather"]}, fields)

    test "reads them as upstreams of the configuration", %{tmp_dir: root} do
      write(root, %{"screen.toml" => @radar, "pages/a.html" => "a"})

      assert {:ok, screen} = Screen.load(root, config: lobby(), upstreams: ["weather"])

      assert %{"radar" => radar} = screen.upstreams
      assert radar.base_url == "https://maps.dwd.de/geoserver/dwd/wms"
      assert radar.origin == :manifest
      assert radar.methods == ["GET"]
      assert {radar.cache_ttl, radar.stale_ttl, radar.refresh} == {300_000, 3_600_000, true}
      assert {radar.header, radar.query} == {nil, nil}
      assert radar.accepted_types == ["image/png"]
      assert radar.cache_size == 20_000_000
      assert radar.description == "DWD rain radar frames"
    end

    test "with a cache_size the host allows", %{tmp_dir: root} do
      write(root, %{"screen.toml" => @radar, "pages/a.html" => "a"})

      assert {:ok, _screen} = Screen.load(root, config: lobby(), max_cache_size: 20_000_000)

      assert errors(root, config: lobby(), max_cache_size: 10_000_000) == [
               "upstream.radar.cache_size must not be larger than the host's upstream_cache_size"
             ]
    end

    test "only for allowed hosts", %{tmp_dir: root} do
      write(root, %{"screen.toml" => @radar, "pages/a.html" => "a"})

      assert {:ok, _screen} = Screen.load(root, config: lobby(repo_upstream_hosts: ["*.dwd.de"]))

      assert {:ok, _screen} =
               Screen.load(root, config: lobby(repo_upstream_hosts: ["maps.dwd.de"]))

      assert errors(root, config: lobby(repo_upstream_hosts: ["dwd.de", "*.example.com"])) ==
               [~s(upstream.radar.url: host "maps.dwd.de" is not allowed for this configuration)]

      assert errors(root, config: lobby(repo_upstreams: false)) ==
               ["upstreams in the manifest are not allowed for this configuration"]
    end

    test "with restricted keys and values", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => """
        [upstream.weather]
        url       = "https://weather.example.com"
        cache_ttl = "5m"

        [upstream.plain]
        url       = "http://plain.example.com"
        cache_ttl = "30s"
        header    = "Authorization"

        [upstream.nottl]
        url = "https://nottl.example.com/?a=1"

        [[page]]
        path = "a.html"
        uses = ["plain"]
        """,
        "pages/a.html" => "a"
      })

      assert errors(root, config: lobby(), upstreams: ["weather"]) == [
               "upstream.nottl.url must be an https URL without credentials, query or fragment",
               "upstream.nottl.cache_ttl is missing",
               "upstream.plain.url must be an https URL without credentials, query or fragment",
               ~s(upstream.plain: unknown key "header"),
               "upstream.plain.cache_ttl must be at least 1m",
               "upstream.weather: an upstream of the host configuration has this name"
             ]
    end
  end

  describe "validator/1" do
    defp config(fields \\ []) do
      struct!(%Config{name: "lobby", repo: "file:///x", ref: "main"}, fields)
    end

    test "reads the manifest from the subdir", %{tmp_dir: root} do
      write(root, %{"lobby/screen.toml" => @one_page, "lobby/pages/a.html" => "a"})

      assert Screen.validator(config(subdir: "lobby")).(root) == :ok
      assert {:error, "screen.toml is missing"} = Screen.validator(config()).(root)
    end

    test "uses the configured manifest", %{tmp_dir: root} do
      write(root, %{"rotations/kitchen.toml" => @one_page, "pages/a.html" => "a"})

      assert Screen.validator(config(manifest: "rotations/kitchen.toml")).(root) == :ok
    end

    test "rejects a missing subdir", %{tmp_dir: root} do
      assert Screen.validator(config(subdir: "nope")).(root) ==
               {:error, ~s(subdir "nope" does not exist)}
    end

    test "joins all errors into one message", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => ~s(rotation = "shuffle"\n[[page]]\n),
        "pages/a.html" => "a"
      })

      assert {:error,
              ~s(screen.rotation must be one of: "sequential", "random"; page #1.path is missing)} =
               Screen.validator(config()).(root)
    end

    test "keeps an invalid revision from being published", %{tmp_dir: tmp_dir} do
      src = Path.join(tmp_dir, "src")
      url = GitFixture.init(src)
      opts = [cache_dir: Path.join(tmp_dir, "cache"), validate: Screen.validator(config())]

      good = GitFixture.commit(src, %{"screen.toml" => @one_page, "pages/a.html" => "a"})
      assert {:ok, ^good} = RevisionStore.publish(url, "main", opts)

      bad =
        GitFixture.commit(src, %{
          "screen.toml" => ~s([[page]]\npath = "gone.html"\nduration = "1s"\n)
        })

      assert {:error, {:rejected, ^bad, ~s(page #1.path "gone.html" is not a file in pages/)}} =
               RevisionStore.publish(url, "main", opts)

      assert RevisionStore.last_good(url, "main", opts) == {:ok, good}
    end
  end
end
