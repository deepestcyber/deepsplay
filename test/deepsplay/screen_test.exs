defmodule Deepsplay.ScreenTest do
  use ExUnit.Case, async: true

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.RevisionStore
  alias Deepsplay.Screen
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

    test "ignores a [backend] table with a warning", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => ~s([backend]\ncommand = "x"\n) <> @one_page,
        "pages/a.html" => "a"
      })

      assert {:ok, %Screen{warnings: ["[backend] is not supported yet and is ignored"]}} =
               Screen.load(root)
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
      assert [%{when: [%{from: 480, until: 900}]}, %{when: nil}] = screen.pages
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
               ~s[page #1.when from must be "HH:MM" (24-hour)],
               "override #1.when is missing",
               "override #2.priority must be an integer",
               ~s(override #2.path "gone.html" is not a file in pages/),
               ~s(override #2: upstream "nope" is not allowed for this configuration),
               ~s(screen.when_empty.path "missing.html" is not a file in pages/)
             ]
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
