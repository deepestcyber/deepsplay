defmodule DeepsplayWeb.MqttPagesTest do
  # Not async: uses the global host configuration and the global MQTT
  # connection.
  use DeepsplayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Deepsplay.ScreenFixture

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Revisions
  alias Deepsplay.Secrets
  alias DeepsplayWeb.Mqtt

  @moduletag :tmp_dir
  # The connection logs its failed connects.
  @moduletag :capture_log

  @files %{
    "screen.toml" => """
    [[page]]
    path = "a.html"

    [[interrupt]]
    name     = "doorbell"
    path     = "bell.html"
    duration = "30s"
    """,
    "pages/a.html" => "a",
    "pages/bell.html" => """
    <script type="application/toml" id="deepsplay-page">
    [params.who]
    type = "string"

    [[variants]]
    label = "Ada"
    query = "who=Ada%20O'Neil"
    </script>
    """
  }

  setup %{tmp_dir: tmp_dir} do
    previous_store = Store.get()
    previous_secrets = :persistent_term.get({Secrets, :secrets}, %{})
    Secrets.put(%{"mqtt_password" => "secret"})

    # Nothing listens there: the connection keeps failing.
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    extra = """
    mqtt_topic = "deepcyber/+/interrupts/+"

    [[config]]
    name       = "hall"
    path       = "#{tmp_dir}/hall"
    mqtt_topic = "deepcyber/+/interrupts/+"

    [mqtt]
    url      = "mqtt://127.0.0.1:#{port}"
    username = "deepsplay"
    password = "{secret:mqtt_password}"
    """

    %{config: config, sha: sha} = setup_screen(tmp_dir, @files, extra)
    {:ok, ^sha} = Revisions.refresh(config)

    # Runs before the fixture puts the host configuration back, so the
    # connection is told here.
    on_exit(fn ->
      Store.put(previous_store)
      Secrets.put(previous_secrets)
      Mqtt.refresh()
    end)

    %{port: port}
  end

  test "the status page shows the connection, its error and the filters", %{
    conn: conn,
    port: port
  } do
    {:ok, view, _html} = live(conn, ~p"/status")
    refute has_element?(view, "#status-mqtt")

    :ok = Mqtt.refresh()
    assert has_element?(view, "#status-mqtt", "mqtt://127.0.0.1:#{port}")
    assert has_element?(view, "#status-mqtt", "user name and password travel unencrypted")

    assert has_element?(
             view,
             "#status-mqtt .mqtt-filter",
             "deepcyber/+/interrupts/+ · hall, lobby · not subscribed"
           )

    # The failed connect reaches the page without a reload.
    assert_eventually(fn ->
      has_element?(view, "#status-mqtt .mqtt-error", "connection refused")
    end)

    assert has_element?(view, "#status-mqtt .mqtt-state", "waiting to reconnect")
  end

  test "the catalog shows the topic and a publish example", %{conn: conn, port: port} do
    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")

    assert has_element?(
             view,
             "#interrupt-doorbell .interrupt-topic",
             "deepcyber/+/interrupts/doorbell"
           )

    assert render(element(view, "#interrupt-doorbell .interrupt-mqtt")) =~
             ~s(mosquitto_pub -h 127.0.0.1 -p #{port} -u deepsplay -P &quot;$PASSWORD&quot; ) <>
               ~s(-t &quot;deepcyber/+/interrupts/doorbell&quot; -m &#39;{&quot;who&quot;:&quot;Ada O&#39;\\&#39;&#39;Neil&quot;}&#39;)
  end

  test "the catalog shows no MQTT without a filter", %{conn: conn} do
    {:ok, host_config} = Store.get()
    lobby = %{host_config.configs["lobby"] | mqtt_topic: nil}
    Store.put({:ok, put_in(host_config.configs["lobby"], lobby)})

    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")
    assert has_element?(view, "#interrupt-doorbell .interrupt-curl")
    refute has_element?(view, "#interrupt-doorbell .interrupt-mqtt")
  end

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("not reached")
      true -> Process.sleep(20) && assert_eventually(fun, tries - 1)
    end
  end
end
