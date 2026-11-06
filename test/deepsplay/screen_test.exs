defmodule Deepsplay.ScreenTest do
  use ExUnit.Case, async: true

  alias Deepsplay.GitFixture
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.RevisionStore
  alias Deepsplay.Screen
  alias Deepsplay.Screen.Page

  @moduletag :tmp_dir

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
    test "reads title, rotation and pages", %{tmp_dir: root} do
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
        "welcome/index.html" => "w",
        "weather/index.html" => "x"
      })

      assert {:ok, screen} = Screen.load(root, upstreams: ["weather"])

      assert %Screen{title: "Lobby", rotation: :random, warnings: []} = screen

      assert screen.pages == [
               %Page{path: "welcome/index.html", duration: 30_000, weight: 3.0, uses: []},
               %Page{path: "weather/index.html", duration: 45_000, weight: 0.5, uses: ["weather"]}
             ]
    end

    test "applies defaults", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" => ~s([[page]]\npath = "a.html"\nduration = "10s"\n),
        "a.html" => "a"
      })

      assert {:ok, %Screen{title: nil, rotation: :sequential, pages: [page]}} = Screen.load(root)
      assert page.weight == 1.0
      assert page.uses == []
    end

    test "ignores a [backend] table with a warning", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          ~s([backend]\ncommand = "x"\n[[page]]\npath = "a.html"\nduration = "10s"\n),
        "a.html" => "a"
      })

      assert {:ok, %Screen{warnings: ["[backend] is not supported yet and is ignored"]}} =
               Screen.load(root)
    end
  end

  describe "load/2 rejects" do
    test "a missing manifest", %{tmp_dir: root} do
      assert errors(root) == ["screen.toml is missing"]
    end

    test "a manifest that is too large", %{tmp_dir: root} do
      write(root, %{"screen.toml" => "# " <> String.duplicate("x", 70_000)})
      assert [error] = errors(root)
      assert error =~ "larger than 64 KiB"
    end

    test "invalid TOML", %{tmp_dir: root} do
      write(root, %{"screen.toml" => "[[page"})
      assert [error] = errors(root)
      assert error =~ "invalid TOML"
    end

    test "a manifest without pages", %{tmp_dir: root} do
      write(root, %{"screen.toml" => ~s(title = "Empty"\n)})
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
        "a.html" => "a"
      })

      errors = errors(root)

      assert ~s(screen.rotation must be one of: "sequential", "random") in errors
      assert ~s(screen: unknown key "colour") in errors
      assert Enum.any?(errors, &(&1 =~ "page #1.duration must be a duration"))
      assert "page #1.weight must be a number greater than 0" in errors
      assert ~s(page #1: unknown key "wieght") in errors
    end

    test "missing required page keys", %{tmp_dir: root} do
      write(root, %{"screen.toml" => "[[page]]\n"})
      errors = errors(root)

      assert "page #1.path is missing" in errors
      assert "page #1.duration is missing" in errors
    end

    test "paths outside the root, missing files and directories", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")

      write(root, %{
        "screen.toml" => """
        [[page]]
        path = "../outside.html"
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
        """,
        "dir/index.html" => "x"
      })

      write(tmp_dir, %{"outside.html" => "x"})

      errors = errors(root)

      assert ~s(page #1.path must not contain "..") in errors
      assert "page #2.path must be a relative path" in errors
      assert ~s(page #3.path "missing.html" does not exist) in errors
      assert ~s(page #4.path "dir" is not a regular file) in errors
    end

    test "upstreams the configuration does not allow", %{tmp_dir: root} do
      write(root, %{
        "screen.toml" =>
          ~s([[page]]\npath = "a.html"\nduration = "1s"\nuses = ["weather", "news"]\n),
        "a.html" => "a"
      })

      assert errors(root, upstreams: ["weather"]) == [
               ~s(page #1: upstream "news" is not allowed for this configuration)
             ]
    end
  end

  describe "validator/1" do
    defp config(subdir \\ "", upstreams \\ []) do
      %Config{name: "lobby", repo: "file:///x", ref: "main", subdir: subdir, upstreams: upstreams}
    end

    test "accepts a valid revision and reads screen.toml from subdir", %{tmp_dir: root} do
      write(root, %{
        "screens/lobby/screen.toml" => ~s([[page]]\npath = "a.html"\nduration = "1s"\n),
        "screens/lobby/a.html" => "a"
      })

      assert Screen.validator(config("screens/lobby")).(root) == :ok
      assert {:error, "screen.toml is missing"} = Screen.validator(config()).(root)
    end

    test "rejects a missing subdir", %{tmp_dir: root} do
      assert Screen.validator(config("nope")).(root) == {:error, ~s(subdir "nope" does not exist)}
    end

    test "joins all errors into one message", %{tmp_dir: root} do
      write(root, %{"screen.toml" => "[[page]]\n"})

      assert {:error, "page #1.path is missing; page #1.duration is missing"} =
               Screen.validator(config()).(root)
    end

    test "keeps an invalid revision from being published", %{tmp_dir: tmp_dir} do
      src = Path.join(tmp_dir, "src")
      url = GitFixture.init(src)
      opts = [cache_dir: Path.join(tmp_dir, "cache"), validate: Screen.validator(config())]

      good =
        GitFixture.commit(src, %{
          "screen.toml" => ~s([[page]]\npath = "a.html"\nduration = "1s"\n),
          "a.html" => "a"
        })

      assert {:ok, ^good} = RevisionStore.publish(url, "main", opts)

      bad =
        GitFixture.commit(src, %{
          "screen.toml" => ~s([[page]]\npath = "gone.html"\nduration = "1s"\n)
        })

      assert {:error, {:rejected, ^bad, ~s(page #1.path "gone.html" does not exist)}} =
               RevisionStore.publish(url, "main", opts)

      assert RevisionStore.last_good(url, "main", opts) == {:ok, good}
    end
  end
end
