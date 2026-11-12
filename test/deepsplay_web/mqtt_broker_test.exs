defmodule DeepsplayWeb.MqttBrokerTest do
  # Against a real mosquitto with TLS and a password file, started for each
  # test. Needs mosquitto, mosquitto_pub, mosquitto_passwd and openssl;
  # excluded otherwise (test_helper.exs).
  #
  # Not async: uses the global host configuration and secrets.
  use DeepsplayWeb.ConnCase, async: false

  import Deepsplay.ScreenFixture
  import ExUnit.CaptureLog

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Revisions
  alias Deepsplay.Secrets
  alias DeepsplayWeb.Interrupts
  alias DeepsplayWeb.Mqtt

  @moduletag :tmp_dir
  @moduletag :mosquitto

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
    </script>
    """
  }

  setup %{tmp_dir: tmp_dir} do
    broker = start_broker(tmp_dir)

    previous = :persistent_term.get({Secrets, :secrets}, %{})
    Secrets.put(%{"mqtt_password" => "test-pass"})
    on_exit(fn -> Secrets.put(previous) end)

    Interrupts.clear()
    %{broker: broker}
  end

  # The host configuration for the broker, with `mqtt` lines added to its
  # [mqtt] section and `topic` as the configuration's filter.
  defp configure(tmp_dir, broker, opts \\ []) do
    topic = Keyword.get(opts, :topic, "deepcyber/lobby/interrupts/+")
    password = Keyword.get(opts, :password_secret, "mqtt_password")

    extra = """
    mqtt_topic = "#{topic}"

    [mqtt]
    url      = "mqtts://localhost:#{broker.tls_port}"
    username = "deepsplay"
    password = "{secret:#{password}}"
    ca_file  = "#{broker.ca}"
    client_id = "deepsplay-test"
    """

    %{config: config, sha: sha} = setup_screen(Path.join(tmp_dir, "screen"), @files, extra)
    {:ok, ^sha} = Revisions.refresh(config)
    :ok
  end

  defp start_mqtt do
    name = :"mqtt_#{System.unique_integer([:positive])}"
    start_supervised!({Mqtt, name: name})
    name
  end

  test "connects with TLS and a password; a message starts the interrupt", ctx do
    configure(ctx.tmp_dir, ctx.broker)
    mqtt = start_mqtt()
    await(mqtt, &match?(%{state: :connected}, &1))

    assert %{tls: true, filters: ["deepcyber/lobby/interrupts/+"], last_error: nil} =
             Mqtt.info(mqtt)

    :ok = Interrupts.subscribe("lobby")
    publish(ctx.broker, "deepcyber/lobby/interrupts/doorbell", ~s({"who": "Ada"}))

    assert_receive {:interrupt, %{name: "doorbell", url: url}}, 5_000
    assert url =~ "bell.html?who=Ada"
    # Recorded right after the event is sent.
    last =
      Enum.find_value(1..50, fn _try ->
        Interrupts.last("lobby")["doorbell"] || (Process.sleep(20) && nil)
      end)

    assert %{source: :mqtt, status: 202} = last
  end

  test "a retained message is ignored, a live one is not", ctx do
    publish(ctx.broker, "deepcyber/lobby/interrupts/doorbell", ~s({"who": "old"}), ["-r"])

    configure(ctx.tmp_dir, ctx.broker)
    :ok = Interrupts.subscribe("lobby")
    mqtt = start_mqtt()
    await(mqtt, &match?(%{state: :connected}, &1))

    publish(ctx.broker, "deepcyber/lobby/interrupts/doorbell", ~s({"who": "new"}))
    assert_receive {:interrupt, %{url: url}}, 5_000
    assert url =~ "who=new"
    refute_receive {:interrupt, _payload}, 300
  end

  test "a changed filter is subscribed without reconnecting", ctx do
    configure(ctx.tmp_dir, ctx.broker)
    mqtt = start_mqtt()
    %{since: since} = await(mqtt, &match?(%{state: :connected}, &1))

    {:ok, host_config} = Store.get()
    lobby = %{host_config.configs["lobby"] | mqtt_topic: "elsewhere/+"}
    Store.put({:ok, put_in(host_config.configs["lobby"], lobby)})
    :ok = Mqtt.refresh(mqtt)
    await(mqtt, &match?(%{filters: ["elsewhere/+"]}, &1))
    assert %{state: :connected, since: ^since} = Mqtt.info(mqtt)

    :ok = Interrupts.subscribe("lobby")
    publish(ctx.broker, "deepcyber/lobby/interrupts/doorbell", "")
    publish(ctx.broker, "elsewhere/doorbell", "")
    assert_receive {:interrupt, %{name: "doorbell"}}, 5_000
    refute_receive {:interrupt, _payload}, 300
  end

  test "a wrong password is reported and retried", ctx do
    Secrets.put(%{"mqtt_password" => "test-pass", "wrong" => "nope"})
    configure(ctx.tmp_dir, ctx.broker, password_secret: "wrong")

    capture_log(fn ->
      mqtt = start_mqtt()

      assert %{last_error: "not authorised (user name or password)"} =
               await(mqtt, &match?(%{state: :waiting}, &1))
    end)
  end

  test "a lost broker is reconnected to", ctx do
    configure(ctx.tmp_dir, ctx.broker)
    mqtt = start_mqtt()
    await(mqtt, &match?(%{state: :connected}, &1))

    capture_log(fn ->
      stop_broker(ctx.broker)
      await(mqtt, &match?(%{state: :waiting, last_error: "connection closed"}, &1))

      start_broker(ctx.tmp_dir, ctx.broker)
      # The first retry comes after 1 second.
      await(mqtt, &match?(%{state: :connected}, &1), 5_000)
    end)

    :ok = Interrupts.subscribe("lobby")
    publish(ctx.broker, "deepcyber/lobby/interrupts/doorbell", "")
    assert_receive {:interrupt, %{name: "doorbell"}}, 5_000
  end

  test "removing [mqtt] disconnects", ctx do
    configure(ctx.tmp_dir, ctx.broker)
    mqtt = start_mqtt()
    await(mqtt, &match?(%{state: :connected}, &1))

    {:ok, host_config} = Store.get()
    Store.put({:ok, %{host_config | mqtt: nil}})
    :ok = Mqtt.refresh(mqtt)
    assert Mqtt.info(mqtt) == nil
  end

  # Polls the connection's info until `fun` accepts it.
  defp await(mqtt, fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> Mqtt.info(mqtt) end)
    |> Enum.find(fn info ->
      cond do
        info != nil and fun.(info) -> true
        System.monotonic_time(:millisecond) > deadline -> flunk("not reached: #{inspect(info)}")
        true -> Process.sleep(20) && false
      end
    end)
  end

  defp publish(broker, topic, payload, extra \\ []) do
    args =
      ~w(-h localhost -p #{broker.plain_port} -u deepsplay -P test-pass -q 1 -t #{topic}) ++
        if(payload == "", do: ["-n"], else: ["-m", payload]) ++ extra

    {_out, 0} = System.cmd("mosquitto_pub", args, stderr_to_stdout: true)
  end

  # A mosquitto with a TLS listener (for deepsplay) and a plain one (for
  # mosquitto_pub), both on 127.0.0.1, with a password file. Certificates
  # come from a CA made for the test.
  defp start_broker(tmp_dir, existing \\ nil) do
    dir = Path.join(tmp_dir, "broker")

    broker =
      existing ||
        (
          File.mkdir_p!(dir)
          openssl(dir, ~w(ecparam -name prime256v1 -genkey -noout -out ca.key))
          openssl(dir, ~w(req -x509 -new -key ca.key -out ca.pem -days 1 -subj /CN=test-ca))
          openssl(dir, ~w(ecparam -name prime256v1 -genkey -noout -out server.key))
          openssl(dir, ~w(req -new -key server.key -out server.csr -subj /CN=localhost))
          File.write!(Path.join(dir, "san.ext"), "subjectAltName=DNS:localhost\n")

          openssl(
            dir,
            ~w(x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 1 -extfile san.ext)
          )

          File.write!(Path.join(dir, "passwd"), "")
          File.chmod!(Path.join(dir, "passwd"), 0o600)
          File.chmod!(Path.join(dir, "server.key"), 0o600)

          {_out, 0} =
            System.cmd("mosquitto_passwd", ["-b", "passwd", "deepsplay", "test-pass"],
              cd: dir,
              stderr_to_stdout: true
            )

          tls_port = free_port()
          plain_port = free_port()

          File.write!(Path.join(dir, "mosquitto.conf"), """
          per_listener_settings false
          allow_anonymous false
          password_file #{dir}/passwd
          listener #{tls_port} 127.0.0.1
          cafile #{dir}/ca.pem
          certfile #{dir}/server.pem
          keyfile #{dir}/server.key
          listener #{plain_port} 127.0.0.1
          """)

          %{dir: dir, ca: Path.join(dir, "ca.pem"), tls_port: tls_port, plain_port: plain_port}
        )

    port =
      Port.open({:spawn_executable, System.find_executable("mosquitto")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", Path.join(dir, "mosquitto.conf")]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    broker = Map.put(broker, :os_pid, os_pid)
    on_exit(fn -> System.cmd("kill", ["#{os_pid}"], stderr_to_stdout: true) end)
    await_port(broker.plain_port)
    broker
  end

  defp stop_broker(%{os_pid: os_pid}) do
    {_out, 0} = System.cmd("kill", ["#{os_pid}"])
  end

  defp openssl(dir, args) do
    {_out, 0} = System.cmd("openssl", args, cd: dir, stderr_to_stdout: true)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp await_port(port, tries \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, _reason} when tries > 0 ->
        Process.sleep(20)
        await_port(port, tries - 1)

      {:error, reason} ->
        flunk("mosquitto did not start: #{inspect(reason)}")
    end
  end
end
