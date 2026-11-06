defmodule Deepsplay.HostConfigTest do
  use ExUnit.Case, async: true

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Config

  @transports ["https", "ssh"]

  @valid """
  [server]
  cache_dir      = "/var/lib/deepsplay/cache"
  default_config = "lobby"
  poll_interval  = "1m"
  keep_revisions = 5

  [[config]]
  name      = "lobby"
  repo      = "https://github.com/example/lobby-screen.git"
  ref       = "main"
  subdir    = "screens/lobby"
  manifest  = "rotations/lobby.toml"
  upstreams = ["weather"]

  [[config]]
  name       = "kitchen"
  repo       = "git@github.com:example/private-screens.git"
  ref        = "kitchen"
  credential = "github_deploy_key"

  [upstream.weather]
  base_url = "https://api.example.com/v1"
  """

  defp parse(toml), do: HostConfig.parse(toml, transports: @transports)

  defp errors(toml) do
    assert {:error, errors} = parse(toml)
    errors
  end

  defp minimal(extra \\ "") do
    """
    [server]
    cache_dir      = "/cache"
    default_config = "lobby"

    [[config]]
    name = "lobby"
    repo = "https://example.com/lobby.git"
    ref  = "main"
    #{extra}
    """
  end

  describe "parse/2 with a valid file" do
    test "reads server settings and configurations" do
      assert {:ok, %HostConfig{} = host_config} = parse(@valid)

      assert host_config.cache_dir == "/var/lib/deepsplay/cache"
      assert host_config.default_config == "lobby"
      assert host_config.poll_interval == 60_000
      assert host_config.keep_revisions == 5

      assert %{
               "lobby" => %Config{
                 name: "lobby",
                 repo: "https://github.com/example/lobby-screen.git",
                 ref: "main",
                 subdir: "screens/lobby",
                 manifest: "rotations/lobby.toml",
                 upstreams: ["weather"],
                 credential: nil
               },
               "kitchen" => %Config{
                 subdir: "",
                 manifest: "screen.toml",
                 upstreams: [],
                 credential: "github_deploy_key"
               }
             } = host_config.configs
    end

    test "accepts a local path instead of repo and ref" do
      toml =
        String.replace(
          minimal(),
          ~s(repo = "https://example.com/lobby.git"\nref  = "main"),
          ~s(path = "/srv/screens/")
        )

      assert {:ok,
              %{
                configs: %{"lobby" => %Config{path: "/srv/screens", repo: nil, ref: nil} = config}
              }} =
               parse(toml)

      assert Config.local?(config)
    end

    test "applies defaults" do
      assert {:ok, host_config} = parse(minimal())
      assert host_config.poll_interval == 30_000
      assert host_config.keep_revisions == 3
    end

    test "expands a relative cache_dir" do
      toml = String.replace(minimal(), ~s("/cache"), ~s("tmp/cache"))
      assert {:ok, host_config} = parse(toml)
      assert host_config.cache_dir == Path.expand("tmp/cache")
    end
  end

  describe "parse/2 rejects" do
    test "invalid TOML" do
      assert [error] = errors("[server")
      assert error =~ "invalid TOML"
    end

    test "a missing server table" do
      assert "[server] table is missing" in errors(~s([[config]]\nname = "a"))
    end

    test "missing required keys" do
      errors = errors("[server]\n[[config]]\n")

      assert "server.cache_dir is missing" in errors
      assert "server.default_config is missing" in errors
      assert "config #1.name is missing" in errors
      assert ~s(config #1: needs "repo" and "ref", or "path") in errors
    end

    test "unknown keys, so typos are not silently ignored" do
      errors = errors(minimal("refs = \"main\"") <> "\n[extra]\n")

      assert ~s(config "lobby": unknown key "refs") in errors
      assert ~s(top level: unknown key "extra") in errors
    end

    test "a default_config that matches no configuration" do
      toml = String.replace(minimal(), ~s(default_config = "lobby"), ~s(default_config = "hall"))
      assert ~s(server.default_config "hall" does not match any config) in errors(toml)
    end

    test "duplicate configuration names" do
      toml =
        minimal(~s([[config]]\nname = "lobby"\nrepo = "https://example.com/b.git"\nref = "b"))

      assert ~s(config name "lobby" is defined more than once) in errors(toml)
    end

    test "invalid configuration names" do
      for name <- ["Lobby", "-lobby", "lob by", "lobby/2", String.duplicate("a", 65)] do
        toml = String.replace(minimal(), ~s(name = "lobby"), ~s(name = "#{name}"))
        assert Enum.any?(errors(toml), &(&1 =~ ".name must be 1 to 64 characters")), name
      end
    end

    test "invalid durations and counts" do
      toml =
        String.replace(
          minimal(),
          ~s(default_config = "lobby"),
          ~s(default_config = "lobby"\npoll_interval = "soon"\nkeep_revisions = -1)
        )

      errors = errors(toml)
      assert Enum.any?(errors, &(&1 =~ "server.poll_interval must be a duration"))
      assert "server.keep_revisions must be a non-negative integer" in errors
    end

    test "subdirectories outside the repository" do
      for subdir <- ["/abs", "../up", "a/../../b"] do
        assert Enum.any?(errors(minimal(~s(subdir = "#{subdir}"))), &(&1 =~ ".subdir")), subdir
      end
    end

    test "manifests outside the root or inside pages/" do
      for manifest <- ["../x.toml", "/x.toml", "pages/screen.toml", ""] do
        assert Enum.any?(errors(minimal(~s(manifest = "#{manifest}"))), &(&1 =~ ".manifest")),
               manifest
      end

      assert ~s(config "lobby".manifest must not be inside "pages/") in errors(
               minimal(~s(manifest = "pages/screen.toml"))
             )
    end

    test "a source that is missing, incomplete or mixed" do
      no_source = """
      [server]
      cache_dir = "/c"
      default_config = "a"
      [[config]]
      name = "a"
      """

      assert ~s(config "a": needs "repo" and "ref", or "path") in errors(no_source)

      assert "config \"a\".ref is missing" in errors(
               no_source <> ~s(repo = "https://e.com/a.git"\n)
             )

      mixed = no_source <> ~s(path = "/srv/a"\nref = "main"\n)
      assert ~s(config "a": "ref" cannot be combined with "path") in errors(mixed)
    end

    test "a relative local path" do
      toml =
        String.replace(
          minimal(),
          ~s(repo = "https://example.com/lobby.git"\nref  = "main"),
          ~s(path = "screens")
        )

      assert ~s(config "lobby".path must be an absolute path) in errors(toml)
    end

    test "local paths where they are not allowed" do
      toml =
        String.replace(
          minimal(),
          ~s(repo = "https://example.com/lobby.git"\nref  = "main"),
          ~s(path = "/srv/screens")
        )

      assert {:error, errors} =
               HostConfig.parse(toml, transports: @transports, allow_local_paths: false)

      assert ~s(config "lobby".path is only allowed in development) in errors
    end

    test "upstreams that are not defined" do
      assert ~s(config "lobby": upstream "weather" is not defined) in errors(
               minimal(~s(upstreams = ["weather"]))
             )
    end
  end

  describe "parse/2 repository transports" do
    defp with_repo(repo), do: String.replace(minimal(), "https://example.com/lobby.git", repo)

    test "accepts https, ssh and scp-like URLs" do
      for repo <- [
            "https://example.com/a.git",
            "ssh://git@example.com/a.git",
            "git@example.com:org/a.git"
          ] do
        assert {:ok, _} = parse(with_repo(repo)), repo
      end
    end

    test "rejects other transports and plain paths" do
      for repo <- ["http://example.com/a.git", "git://example.com/a.git", "/srv/a.git"] do
        assert Enum.any?(errors(with_repo(repo)), &(&1 =~ ~s(config "lobby".repo))), repo
      end
    end

    test "rejects file URLs unless the file transport is allowed" do
      toml = with_repo("file:///srv/a.git")

      assert [~s(config "lobby".repo uses transport "file", allowed: https, ssh)] = errors(toml)
      assert {:ok, _} = HostConfig.parse(toml, transports: ["https", "ssh", "file"])
    end

    test "defaults to the transports allowed in this environment" do
      assert "file" in HostConfig.allowed_transports()
      assert {:ok, _} = HostConfig.parse(with_repo("file:///srv/a.git"))
    end
  end

  describe "load/2" do
    @tag :tmp_dir
    test "reads a file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "host.toml")
      File.write!(path, minimal())
      assert {:ok, %HostConfig{default_config: "lobby"}} = HostConfig.load(path)
    end

    test "reports a missing file" do
      assert {:error, [error]} = HostConfig.load("/nonexistent/host.toml")
      assert error =~ "cannot read /nonexistent/host.toml"
    end
  end
end
