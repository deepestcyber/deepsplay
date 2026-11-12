defmodule DeepsplayWeb.MqttTest do
  use ExUnit.Case, async: true

  alias Deepsplay.HostConfig
  alias DeepsplayWeb.Mqtt

  doctest Mqtt

  @spec_a %{
    host: "broker",
    port: 8883,
    tls: true,
    username: "u",
    password: "p",
    client_id: nil,
    ca_file: nil
  }

  defp current(spec, connected, subscribed),
    do: %{spec: spec, connected: connected, subscribed: MapSet.new(subscribed)}

  defp wanted(spec, filters), do: %{spec: spec, filters: MapSet.new(filters)}

  describe "plan/2" do
    test "nothing wanted, nothing there" do
      assert Mqtt.plan(current(nil, false, []), wanted(nil, [])) == []
    end

    test "a broker removed" do
      assert Mqtt.plan(current(@spec_a, true, ["a/+"]), wanted(nil, [])) == [:disconnect]
    end

    test "a changed broker or password reconnects" do
      for change <- [%{port: 1883}, %{password: "new"}, %{username: "v"}, %{client_id: "x"}] do
        assert Mqtt.plan(
                 current(@spec_a, true, ["a/+"]),
                 wanted(Map.merge(@spec_a, change), ["a/+"])
               ) ==
                 [:disconnect, :connect]
      end
    end

    test "filters change only on a live connection" do
      assert Mqtt.plan(current(@spec_a, false, []), wanted(@spec_a, ["a/+"])) == []
      assert Mqtt.plan(current(@spec_a, true, ["a/+"]), wanted(@spec_a, ["a/+"])) == []

      assert Mqtt.plan(current(@spec_a, true, []), wanted(@spec_a, ["b/+", "a/+"])) ==
               [{:subscribe, ["a/+", "b/+"]}]

      assert Mqtt.plan(current(@spec_a, true, ["a/+"]), wanted(@spec_a, [])) ==
               [{:unsubscribe, ["a/+"]}]
    end
  end

  describe "wanted/2" do
    defp host_config(mqtt, configs \\ ""),
      do:
        HostConfig.parse(
          """
          [server]
          cache_dir      = "/cache"
          default_config = "lobby"

          [[config]]
          name = "lobby"
          repo = "https://example.com/lobby.git"
          ref  = "main"
          #{configs}
          #{mqtt}
          """,
          transports: ["https"],
          secrets: ["mqtt_password"]
        )

    test "without [mqtt] or with an unusable host configuration" do
      assert Mqtt.wanted(host_config(""), fn _ -> :error end) == wanted(nil, [])
      assert Mqtt.wanted({:error, ["broken"]}, fn _ -> :error end) == wanted(nil, [])
    end

    test "the broker with the password's value and all filters" do
      result =
        host_config(
          """
          [mqtt]
          url      = "mqtts://broker"
          username = "u"
          password = "{secret:mqtt_password}"
          """,
          """
          mqtt_topic = "a/lobby/+"

          [[config]]
          name       = "hall"
          repo       = "https://example.com/hall.git"
          ref        = "main"
          mqtt_topic = "a/+/+"

          [[config]]
          name = "quiet"
          repo = "https://example.com/quiet.git"
          ref  = "main"
          """
        )

      fetch = fn "mqtt_password" -> {:ok, "p"} end
      assert Mqtt.wanted(result, fetch) == wanted(@spec_a, ["a/lobby/+", "a/+/+"])

      # A secret gone since the file was checked: no password, the broker says why.
      assert Mqtt.wanted(result, fn _ -> :error end).spec.password == nil
    end
  end
end
