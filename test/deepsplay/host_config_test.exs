defmodule Deepsplay.HostConfigTest do
  use ExUnit.Case, async: true

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Config

  doctest Deepsplay.HostConfig.Upstream
  doctest Deepsplay.HostConfig.Mqtt

  @transports ["https", "ssh"]

  @valid """
  [server]
  cache_dir      = "/var/lib/deepsplay/cache"
  default_config = "lobby"
  poll_interval  = "1m"
  keep_revisions = 5
  upstream_cache_size = "1GB"

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

  @secrets ["github_deploy_key", "weather_api"]

  defp parse(toml), do: HostConfig.parse(toml, transports: @transports, secrets: @secrets)

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
      assert host_config.upstream_cache_size == 1_000_000_000

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

    test "reads upstreams" do
      toml =
        minimal() <>
          """
          [upstream.weather]
          base_url    = "https://api.example.com/v1/"
          methods     = ["GET", "POST"]
          header      = "Authorization"
          value       = "Bearer {secret:weather_api}"
          query       = "appid"
          query_value = "{secret:weather_api}"
          cache_ttl   = "60s"
          stale_ttl   = "1h"
          refresh     = true
          accepted_types = ["Image/PNG", "text/*"]
          cache_size  = "20MB"
          timeout     = "5s"
          """

      assert {:ok, %{upstreams: %{"weather" => upstream}}} = parse(toml)

      assert upstream == %Deepsplay.HostConfig.Upstream{
               name: "weather",
               base_url: "https://api.example.com/v1",
               methods: ["GET", "POST"],
               header: "Authorization",
               value: "Bearer {secret:weather_api}",
               query: "appid",
               query_value: "{secret:weather_api}",
               cache_ttl: 60_000,
               stale_ttl: 3_600_000,
               refresh: true,
               accepted_types: ["image/png", "text/*"],
               cache_size: 20_000_000,
               timeout: 5_000
             }
    end

    test "an upstream's cache_size cannot exceed upstream_cache_size" do
      toml =
        String.replace(
          minimal(),
          ~s(default_config = "lobby"),
          ~s(default_config = "lobby"\nupstream_cache_size = "10MB")
        ) <>
          """
          [upstream.tiles]
          base_url   = "https://tiles.example.com"
          cache_ttl  = "1m"
          cache_size = "20MB"
          """

      assert "upstream.tiles.cache_size must not be larger than server.upstream_cache_size" in errors(
               toml
             )
    end

    test "invalid accepted_types" do
      for value <- [
            ~s([]),
            ~s(["png"]),
            ~s(["image/png; charset=x"]),
            ~s(["*/*"]),
            ~s("image/png")
          ] do
        toml =
          minimal() <>
            """
            [upstream.weather]
            base_url       = "https://api.example.com"
            cache_ttl      = "1m"
            accepted_types = #{value}
            """

        assert Enum.any?(
                 errors(toml),
                 &(&1 =~ "upstream.weather.accepted_types must be a list of media types")
               ),
               value
      end
    end

    test "stale_ttl and refresh need cache_ttl" do
      toml =
        minimal() <>
          """
          [upstream.weather]
          base_url  = "https://api.example.com"
          stale_ttl = "1h"
          refresh   = true
          accepted_types = ["image/png"]
          cache_size = "1MB"
          """

      assert {:error, errors} = parse(toml)
      assert ~s(upstream.weather: "accepted_types" needs "cache_ttl") in errors
      assert ~s(upstream.weather: "cache_size" needs "cache_ttl") in errors
      assert ~s(upstream.weather: "stale_ttl" needs "cache_ttl") in errors
      assert ~s(upstream.weather: "refresh" needs "cache_ttl") in errors
    end

    test "manifest upstream rules: server defaults and per-configuration overrides" do
      toml = """
      [server]
      cache_dir           = "/cache"
      default_config      = "lobby"
      repo_upstream_hosts = ["*.dwd.de", "Example.com"]

      [[config]]
      name = "lobby"
      path = "/srv/lobby"

      [[config]]
      name           = "kitchen"
      path           = "/srv/kitchen"
      repo_upstreams = false

      [[config]]
      name                = "hall"
      path                = "/srv/hall"
      repo_upstream_hosts = []
      """

      assert {:ok, host_config} = parse(toml)
      %{"lobby" => lobby, "kitchen" => kitchen, "hall" => hall} = host_config.configs

      assert {lobby.repo_upstreams, lobby.repo_upstream_hosts} ==
               {true, ["*.dwd.de", "example.com"]}

      assert Config.repo_upstream_host?(lobby, "maps.dwd.de")
      refute Config.repo_upstream_host?(lobby, "dwd.de")
      assert Config.repo_upstream_host?(lobby, "EXAMPLE.com")
      refute Config.repo_upstream_host?(lobby, "www.example.com")

      refute Config.repo_upstream_host?(kitchen, "maps.dwd.de")
      assert Config.repo_upstream_host?(hall, "anything.example.org")
    end

    test "invalid manifest upstream rules" do
      toml =
        String.replace(
          minimal(),
          ~s(default_config = "lobby"),
          ~s(default_config = "lobby"\nrepo_upstreams = "yes"\nrepo_upstream_hosts = ["*", "a b"])
        )

      errors = errors(toml)
      assert "server.repo_upstreams must be true or false" in errors
      assert Enum.any?(errors, &(&1 =~ "server.repo_upstream_hosts must be a list of host names"))
    end

    test "descriptions of configurations and upstreams" do
      toml =
        minimal(~s(description = "  Kiosk at the entrance  ")) <>
          """
          [upstream.weather]
          base_url    = "https://api.example.com"
          description = "Forecasts for the lobby"
          """

      assert {:ok, host_config} = parse(toml)
      assert host_config.configs["lobby"].description == "Kiosk at the entrance"
      assert host_config.upstreams["weather"].description == "Forecasts for the lobby"

      assert {:ok, host_config} = parse(minimal(~s(description = "  ")))
      assert host_config.configs["lobby"].description == nil

      long = String.duplicate("x", 501)

      assert Enum.any?(
               errors(minimal(~s(description = "#{long}"))),
               &(&1 =~ "at most 500 characters")
             )

      assert Enum.any?(
               errors(minimal("description = 3")),
               &(&1 =~ ".description must be a string")
             )
    end

    test "backend settings" do
      assert {:ok, host_config} = parse(minimal())
      lobby = host_config.configs["lobby"]
      assert {lobby.backend, lobby.backend_secrets, lobby.backend_memory} == {false, [], nil}

      toml =
        minimal(~s(backend = true\nbackend_secrets = ["weather_api"]\nbackend_memory = "512MB"))

      assert {:ok, host_config} = parse(toml)
      lobby = host_config.configs["lobby"]

      assert {lobby.backend, lobby.backend_secrets, lobby.backend_memory} ==
               {true, ["weather_api"], 512_000_000}

      assert ~s(config "lobby": backend secret "nope" is not defined) in errors(
               minimal(~s(backend_secrets = ["nope"]))
             )
    end

    test "shared state settings" do
      assert {:ok, host_config} = parse(minimal())
      assert host_config.state_dir == "/cache/.state"
      assert host_config.shared_state
      assert host_config.configs["lobby"].state == :default

      toml =
        String.replace(
          minimal(~s(state = "hall")),
          ~s(default_config = "lobby"),
          ~s(default_config = "lobby"\nstate_dir = "/data/state"\nshared_state = false)
        )

      assert {:ok, host_config} = parse(toml)
      assert host_config.state_dir == "/data/state"
      refute host_config.shared_state
      assert host_config.configs["lobby"].state == "hall"

      assert {:ok, host_config} = parse(minimal("state = false"))
      assert host_config.configs["lobby"].state == false

      assert Enum.any?(
               errors(minimal(~s(state = "Not Valid"))),
               &(&1 =~ ".state must be false or a name")
             )

      assert Enum.any?(errors(minimal("state = true")), &(&1 =~ ".state must be false or a name"))
    end

    test "reads default parameters for pages" do
      toml = minimal(~s(params = { theme = "neon", cells = 40, gps = 2.5, fast = true }))

      assert {:ok, %{configs: %{"lobby" => %Config{params: params}}}} = parse(toml)
      assert params == %{"theme" => "neon", "cells" => "40", "gps" => "2.5", "fast" => "true"}

      assert ~s(config "lobby".params value of "x" must be a string, number or boolean) in errors(
               minimal(~s(params = { x = [1] }))
             )
    end

    test "applies defaults" do
      assert {:ok, host_config} = parse(minimal())
      assert host_config.poll_interval == 30_000
      assert host_config.keep_revisions == 3
      assert host_config.upstream_cache_size == 200_000_000
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
          ~s(default_config = "lobby"\npoll_interval = "soon"\nkeep_revisions = -1\nupstream_cache_size = "lots")
        )

      errors = errors(toml)
      assert Enum.any?(errors, &(&1 =~ "server.poll_interval must be a duration"))
      assert "server.keep_revisions must be a non-negative integer" in errors
      assert Enum.any?(errors, &(&1 =~ "server.upstream_cache_size must be a size"))
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

    test "invalid upstreams and undefined secrets" do
      toml =
        minimal() <>
          """
          [upstream.bad]
          base_url = "ftp://x"
          methods  = ["FETCH"]
          header   = "Authorization"

          [upstream.secretive]
          base_url    = "https://api.example.com"
          query       = "key"
          query_value = "{secret:missing}"
          """

      errors = errors(toml)

      assert Enum.any?(errors, &(&1 =~ "upstream.bad.base_url must be an http or https URL"))
      assert Enum.any?(errors, &(&1 =~ "upstream.bad.methods must be a list of"))
      assert ~s(upstream.bad: "header" needs "value") in errors
      assert ~s(upstream.secretive: secret "missing" is not defined) in errors
    end

    test "interrupt_token names a defined secret" do
      assert {:ok, host_config} = parse(minimal())
      assert host_config.configs["lobby"].interrupt_token == nil

      assert {:ok, host_config} = parse(minimal(~s(interrupt_token = "weather_api")))
      assert host_config.configs["lobby"].interrupt_token == "weather_api"

      assert ~s(config "lobby": interrupt_token secret "nope" is not defined) in errors(
               minimal(~s(interrupt_token = "nope"))
             )
    end

    test "a credential naming an undefined secret" do
      toml = minimal(~s(credential = "missing_key"))
      assert ~s(config "lobby": credential secret "missing_key" is not defined) in errors(toml)
    end

    test "upstreams that are not defined" do
      assert ~s(config "lobby": upstream "weather" is not defined) in errors(
               minimal(~s(upstreams = ["weather"]))
             )
    end
  end

  describe "parse/2 MQTT" do
    alias Deepsplay.HostConfig.Mqtt

    defp with_mqtt(mqtt, config_extra \\ "") do
      minimal(config_extra) <> "\n[mqtt]\n" <> mqtt <> "\n"
    end

    defp mqtt_secrets(toml),
      do: HostConfig.parse(toml, transports: @transports, secrets: ["mqtt_password" | @secrets])

    test "is optional" do
      assert {:ok, %HostConfig{mqtt: nil}} = parse(minimal())
      assert {:ok, host_config} = parse(minimal())
      assert host_config.configs["lobby"].mqtt_topic == nil
    end

    test "a broker with TLS, user name, password secret and topic filter" do
      toml =
        with_mqtt(
          """
          url       = "mqtts://broker.example.org"
          username  = "deepsplay"
          password  = "{secret:mqtt_password}"
          client_id = "deepsplay-lobby"
          """,
          ~s(mqtt_topic = "deepcyber/lobby/interrupts/+")
        )

      assert {:ok, host_config} = mqtt_secrets(toml)

      assert host_config.mqtt == %Mqtt{
               host: "broker.example.org",
               port: 8883,
               tls: true,
               username: "deepsplay",
               password_secret: "mqtt_password",
               client_id: "deepsplay-lobby",
               ca_file: nil
             }

      assert host_config.configs["lobby"].mqtt_topic == "deepcyber/lobby/interrupts/+"
    end

    test "plain MQTT with a port, without credentials" do
      assert {:ok, host_config} = parse(with_mqtt(~s(url = "mqtt://localhost:1884")))
      assert %Mqtt{host: "localhost", port: 1884, tls: false, username: nil} = host_config.mqtt
    end

    @tag :tmp_dir
    test "a CA file that exists", %{tmp_dir: dir} do
      ca = Path.join(dir, "ca.pem")
      File.write!(ca, "-----BEGIN CERTIFICATE-----\n")

      assert {:ok, host_config} =
               parse(with_mqtt(~s(url = "mqtts://broker"\nca_file = "#{ca}")))

      assert host_config.mqtt.ca_file == ca

      assert Enum.any?(
               errors(with_mqtt(~s(url = "mqtts://broker"\nca_file = "#{dir}/nope.pem"))),
               &(&1 =~ "mqtt.ca_file cannot be read")
             )

      assert "mqtt.ca_file must be a readable file" in errors(
               with_mqtt(~s(url = "mqtts://broker"\nca_file = "#{dir}"))
             )
    end

    test "rejects a bad URL, a literal password and unknown keys" do
      errors =
        errors(
          with_mqtt("""
          url      = "https://broker.example.org/path"
          username = "deepsplay"
          password = "hunter2"
          qos      = 2
          """)
        )

      assert Enum.any?(errors, &(&1 =~ "mqtt.url must be an mqtts:// or mqtt:// URL"))
      assert Enum.any?(errors, &(&1 =~ "mqtt.password must be a secret reference"))
      assert ~s(mqtt: unknown key "qos") in errors
    end

    test "rejects URLs with credentials, paths or queries" do
      for url <- [
            "mqtts://user:pass@broker",
            "mqtts://broker/topic",
            "mqtts://broker?x=1",
            "mqtts://",
            "broker:8883"
          ] do
        assert Enum.any?(
                 errors(with_mqtt(~s(url = "#{url}"))),
                 &(&1 =~ "mqtt.url must be")
               ),
               url
      end
    end

    test "rejects a missing URL, a password without user name and undefined secrets" do
      assert "mqtt.url is missing" in errors(with_mqtt(~s(username = "deepsplay")))

      assert ~s(mqtt: "password" needs "username") in errors(
               with_mqtt(~s(url = "mqtts://broker"\npassword = "{secret:weather_api}"))
             )

      assert ~s(mqtt: password secret "nope" is not defined) in errors(
               with_mqtt(~s(url = "mqtts://broker"\nusername = "u"\npassword = "{secret:nope}"))
             )
    end

    test "rejects a bad client_id" do
      for id <- ["", "has space", String.duplicate("a", 24)] do
        assert Enum.any?(
                 errors(with_mqtt(~s(url = "mqtts://broker"\nclient_id = "#{id}"))),
                 &(&1 =~ "mqtt.client_id must be")
               ),
               id
      end
    end

    test "topic filters" do
      for filter <- ["a/+", "a/+/b/+", "deepcyber/lobby/interrupts/+"] do
        assert {:ok, _host_config} =
                 parse(with_mqtt(~s(url = "mqtts://broker"), ~s(mqtt_topic = "#{filter}"))),
               filter
      end

      for filter <- [
            "+",
            "a/b",
            "a/#",
            "a/#/+",
            "a//+",
            "$SYS/+",
            "a/b+/+",
            "",
            "a/" <> String.duplicate("b", 256) <> "/+"
          ] do
        assert ~s(config "lobby".mqtt_topic must be a topic filter ending in "/+", without "#") in errors(
                 with_mqtt(~s(url = "mqtts://broker"), ~s(mqtt_topic = "#{filter}"))
               ),
               filter
      end
    end

    test "a topic filter needs an [mqtt] section" do
      assert ~s(config "lobby": mqtt_topic needs an [mqtt] section) in errors(
               minimal(~s(mqtt_topic = "a/+"))
             )
    end

    test "a broken [mqtt] section does not also report topic filters" do
      errors = errors(with_mqtt(~s(url = "nope"), ~s(mqtt_topic = "a/+")))
      refute Enum.any?(errors, &(&1 =~ "needs an [mqtt] section"))
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
