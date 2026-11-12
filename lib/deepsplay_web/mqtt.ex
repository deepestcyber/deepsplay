defmodule DeepsplayWeb.Mqtt do
  @moduledoc """
  The connection to the MQTT broker of the host configuration (ADR 33).

  Always started; idle while the host configuration has no `[mqtt]`. On
  start and whenever the host configuration changes, it compares what is
  wanted (the broker with the resolved password, the `mqtt_topic` filters
  of all configurations) with what it has, see `plan/2`:

    * broker added: connect; removed: disconnect; changed, including the
      password's value: reconnect;
    * only filters changed: subscribe and unsubscribe on the live
      connection.

  A lost or failed connection is retried after 1, 2, 4 … up to 60 seconds,
  reset by a successful connect. MQTT 3.1.1, clean session, QoS 1
  subscriptions. The client id is `client_id` of `[mqtt]`, or
  `deepsplay-` with 8 random characters made once per start.

  Messages go to `DeepsplayWeb.InterruptMessage.dispatch/3`, each in its own
  task, so a crash while handling one does not touch the connection.

  Calls into the client that wait for the broker (connect, subscribe) run in
  a task, one at a time, so `info/0` always answers at once.
  """

  use GenServer

  require Logger

  alias Deepsplay.HostConfig.Mqtt, as: Broker
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.HostConfig.Watcher
  alias Deepsplay.Secrets
  alias DeepsplayWeb.InterruptMessage

  @max_delay 60_000

  @typedoc """
  The broker as the connection needs it: `Deepsplay.HostConfig.Mqtt` with
  the password's value instead of the secret's name.
  """
  @type spec :: %{
          host: String.t(),
          port: pos_integer(),
          tls: boolean(),
          username: String.t() | nil,
          password: String.t() | nil,
          client_id: String.t() | nil,
          ca_file: String.t() | nil
        }

  @typedoc "What the connection has: the broker it uses and its subscriptions."
  @type current :: %{spec: spec() | nil, connected: boolean(), subscribed: MapSet.t(String.t())}

  @typedoc "What the host configuration wants."
  @type wanted :: %{spec: spec() | nil, filters: MapSet.t(String.t())}

  @type action ::
          :connect
          | :disconnect
          | {:subscribe, [String.t()]}
          | {:unsubscribe, [String.t()]}

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The state for the status page: `nil` without `[mqtt]`, otherwise the
  broker, the state of the connection with the time it changed, the last
  error and the subscribed filters.
  """
  @spec info(GenServer.server()) ::
          %{
            broker: String.t(),
            tls: boolean(),
            state: :connecting | :connected | :waiting,
            since: DateTime.t(),
            last_error: String.t() | nil,
            filters: [String.t()]
          }
          | nil
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  Compares the host configuration with the connection now, instead of
  waiting for `{:host_config_changed}`. For tests.
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @doc """
  What the host configuration `result` (from `Store.get/0`) wants, with
  passwords looked up with `fetch` (like `Deepsplay.Secrets.fetch/1`). A host configuration that is not
  usable wants nothing. A missing password secret leaves the password out,
  so the broker reports it.
  """
  @spec wanted(
          {:ok, Deepsplay.HostConfig.t()} | {:error, term()},
          (String.t() -> {:ok, String.t()} | :error)
        ) :: wanted()
  def wanted({:ok, %{mqtt: %Broker{} = broker, configs: configs}}, fetch) do
    spec = %{
      host: broker.host,
      port: broker.port,
      tls: broker.tls,
      username: broker.username,
      password: password(broker.password_secret, fetch),
      client_id: broker.client_id,
      ca_file: broker.ca_file
    }

    filters =
      for {_name, %{mqtt_topic: filter}} <- configs, filter != nil, into: MapSet.new(), do: filter

    %{spec: spec, filters: filters}
  end

  def wanted(_no_broker_or_unusable, _fetch), do: %{spec: nil, filters: MapSet.new()}

  defp password(nil, _fetch), do: nil

  defp password(name, fetch) do
    case fetch.(name) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @doc """
  The actions that take the connection from `current` to `wanted`.

      iex> DeepsplayWeb.Mqtt.plan(
      ...>   %{spec: nil, connected: false, subscribed: MapSet.new()},
      ...>   %{spec: %{host: "b"}, filters: MapSet.new(["a/+"])}
      ...> )
      [:connect]

      iex> DeepsplayWeb.Mqtt.plan(
      ...>   %{spec: %{host: "b"}, connected: true, subscribed: MapSet.new(["a/+", "b/+"])},
      ...>   %{spec: %{host: "b"}, filters: MapSet.new(["b/+", "c/+"])}
      ...> )
      [{:unsubscribe, ["a/+"]}, {:subscribe, ["c/+"]}]
  """
  @spec plan(current(), wanted()) :: [action()]
  def plan(%{spec: nil}, %{spec: nil}), do: []
  def plan(%{spec: nil}, %{spec: _new}), do: [:connect]
  def plan(%{spec: _old}, %{spec: nil}), do: [:disconnect]
  def plan(%{spec: old}, %{spec: new}) when old != new, do: [:disconnect, :connect]

  # Same broker: subscriptions only, and only on a live connection; a new
  # connection subscribes to all filters.
  def plan(%{connected: false}, _wanted), do: []

  def plan(%{subscribed: subscribed}, %{filters: filters}) do
    gone = subscribed |> MapSet.difference(filters) |> Enum.sort()
    new = filters |> MapSet.difference(subscribed) |> Enum.sort()

    if(gone == [], do: [], else: [{:unsubscribe, gone}]) ++
      if new == [], do: [], else: [{:subscribe, new}]
  end

  # Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    # emqtt logs every packet at debug.
    Logger.put_application_level(:emqtt, :info)
    :ok = Phoenix.PubSub.subscribe(Deepsplay.PubSub, Watcher.topic())

    state = %{
      spec: nil,
      filters: MapSet.new(),
      client: nil,
      client_id: "deepsplay-" <> random_suffix(),
      connected: false,
      subscribed: MapSet.new(),
      task: nil,
      dirty: false,
      state: nil,
      since: nil,
      last_error: nil,
      delay: 1_000,
      timer: nil
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: {:noreply, reconcile(state)}

  @impl true
  def handle_call(:info, _from, %{spec: nil} = state), do: {:reply, nil, state}

  def handle_call(:info, _from, state) do
    info = %{
      broker: "#{state.spec.host}:#{state.spec.port}",
      tls: state.spec.tls,
      state: state.state,
      since: state.since,
      last_error: state.last_error,
      filters: Enum.sort(state.subscribed)
    }

    {:reply, info, state}
  end

  def handle_call(:refresh, _from, state), do: {:reply, :ok, reconcile(state)}

  @impl true
  def handle_info({:host_config_changed}, state), do: {:noreply, reconcile(state)}

  def handle_info(:retry, state), do: {:noreply, reconcile(%{state | timer: nil})}

  def handle_info({:publish, %{topic: topic, payload: payload} = message}, state) do
    retain = Map.get(message, :retain, false)
    Task.start(fn -> InterruptMessage.dispatch(topic, payload, retain) end)
    {:noreply, state}
  end

  # The result of a task talking to the broker.
  def handle_info({ref, result}, %{task: {ref, client, job}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    state =
      if client == state.client,
        do: finished(job, result, state),
        else: state

    {:noreply, if(state.dirty, do: reconcile(%{state | dirty: false}), else: state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {ref, client, _job}} = state) do
    state = %{state | task: nil}

    state =
      if client == state.client,
        do: lost(state, "#{inspect(reason)}"),
        else: state

    {:noreply, state}
  end

  def handle_info({:EXIT, client, reason}, %{client: client} = state) do
    {:noreply, lost(%{state | client: nil}, describe_exit(reason))}
  end

  # Old clients, finished tasks.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_client(state.client)
    :ok
  end

  # Applies the plan, or defers it while a task talks to the broker.
  defp reconcile(%{task: {_ref, _client, _job}} = state), do: %{state | dirty: true}

  defp reconcile(state) do
    wanted = wanted(Store.get(), &Secrets.fetch/1)
    current = %{spec: state.spec, connected: state.connected, subscribed: state.subscribed}

    state = %{state | filters: wanted.filters}

    # Connecting, subscribing and unsubscribing each start a task; once one
    # runs, the rest waits for its result and the next reconcile.
    Enum.reduce(plan(current, wanted), state, fn
      _action, %{task: {_ref, _client, _job}} = state -> %{state | dirty: true}
      :disconnect, state -> disconnect(state)
      :connect, state -> connect(%{state | spec: wanted.spec, delay: 1_000})
      {:unsubscribe, filters}, state -> run(state, {:unsubscribe, filters})
      {:subscribe, filters}, state -> run(state, {:subscribe, filters})
    end)
    |> retry_if_waiting(wanted)
  end

  # A broker that is wanted but not connected and not being connected to
  # (a retry that came due) is connected to now.
  defp retry_if_waiting(%{spec: spec, client: nil, task: nil, timer: nil} = state, %{spec: spec})
       when spec != nil,
       do: connect(state)

  defp retry_if_waiting(state, _wanted), do: state

  defp connect(state) do
    {:ok, client} = :emqtt.start_link(client_opts(state.spec, state.client_id))
    Logger.info("MQTT: connecting to #{state.spec.host}:#{state.spec.port}")

    %{state | client: client, connected: false, subscribed: MapSet.new()}
    |> put_state(:connecting)
    |> run({:connect, Enum.sort(state.filters)})
  end

  defp disconnect(state) do
    stop_client(state.client)
    if state.timer, do: Process.cancel_timer(state.timer)

    if state.spec,
      do: Logger.info("MQTT: disconnected from #{state.spec.host}:#{state.spec.port}")

    %{
      state
      | spec: nil,
        client: nil,
        connected: false,
        subscribed: MapSet.new(),
        state: nil,
        since: nil,
        last_error: nil,
        timer: nil,
        task: nil
    }
  end

  defp stop_client(nil), do: :ok

  defp stop_client(client) do
    Process.unlink(client)
    :emqtt.stop(client)
  catch
    :exit, _gone -> :ok
  end

  # One task at a time talks to the broker; its result comes back as
  # `{ref, result}`.
  defp run(%{client: client} = state, job) do
    task = Task.async(fn -> work(client, job) end)
    %{state | task: {task.ref, client, job}}
  end

  defp work(client, {:connect, filters}) do
    with {:ok, _props} <- :emqtt.connect(client),
         :ok <- subscribe(client, filters) do
      {:ok, filters}
    end
  end

  defp work(client, {:subscribe, filters}) do
    with :ok <- subscribe(client, filters), do: {:ok, filters}
  end

  defp work(client, {:unsubscribe, filters}) do
    case :emqtt.unsubscribe(client, filters) do
      {:ok, _props, _codes} -> {:ok, filters}
      {:error, reason} -> {:error, reason}
    end
  end

  defp subscribe(_client, []), do: :ok

  defp subscribe(client, filters) do
    case :emqtt.subscribe(client, Enum.map(filters, &{&1, [qos: 1]})) do
      {:ok, _props, codes} ->
        case for {filter, code} <- Enum.zip(filters, codes), code not in [0, 1, 2], do: filter do
          [] -> :ok
          refused -> {:error, "the broker refused #{Enum.join(refused, ", ")}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finished({:connect, _filters}, {:ok, filters}, state) do
    Logger.info("MQTT: connected to #{state.spec.host}:#{state.spec.port}")

    %{state | connected: true, subscribed: MapSet.new(filters), delay: 1_000, last_error: nil}
    |> put_state(:connected)
    |> Map.put(:dirty, true)
  end

  defp finished({:subscribe, _filters}, {:ok, filters}, state),
    do: %{state | subscribed: MapSet.union(state.subscribed, MapSet.new(filters))}

  defp finished({:unsubscribe, _filters}, {:ok, filters}, state),
    do: %{state | subscribed: MapSet.difference(state.subscribed, MapSet.new(filters))}

  # A connection that failed, or subscriptions the broker refused: start
  # over after the delay.
  defp finished(_job, {:error, reason}, state) do
    stop_client(state.client)
    lost(%{state | client: nil}, describe_error(reason))
  end

  defp lost(state, error) do
    stop_client(state.client)

    Logger.warning(
      "MQTT: #{state.spec.host}:#{state.spec.port}: #{error}, retrying in #{div(state.delay, 1000)} s"
    )

    timer = if state.timer, do: state.timer, else: Process.send_after(self(), :retry, state.delay)

    %{
      state
      | client: nil,
        connected: false,
        subscribed: MapSet.new(),
        last_error: error,
        delay: min(state.delay * 2, @max_delay),
        timer: timer
    }
    |> put_state(:waiting)
  end

  defp put_state(%{state: same} = state, same), do: state
  defp put_state(state, new), do: %{state | state: new, since: DateTime.utc_now()}

  defp client_opts(spec, generated_id) do
    [
      host: String.to_charlist(spec.host),
      port: spec.port,
      clientid: spec.client_id || generated_id,
      clean_start: true,
      proto_ver: :v4,
      keepalive: 60,
      connect_timeout: 10,
      owner: self()
    ] ++
      if(spec.tls, do: [ssl: true, ssl_opts: tls_opts(spec)], else: []) ++
      if(spec.username, do: [username: spec.username], else: []) ++
      if spec.password, do: [password: spec.password], else: []
  end

  # The broker's certificate and host name are always checked.
  defp tls_opts(spec) do
    host = String.to_charlist(spec.host)

    cas =
      if spec.ca_file,
        do: [cacertfile: String.to_charlist(spec.ca_file)],
        else: [cacerts: :public_key.cacerts_get()]

    sni =
      case :inet.parse_address(host) do
        {:ok, _ip} -> []
        {:error, _name} -> [server_name_indication: host]
      end

    [
      verify: :verify_peer,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ cas ++ sni
  end

  defp describe_exit({:shutdown, reason}), do: describe_error(reason)
  defp describe_exit(reason), do: describe_error(reason)

  defp describe_error({:tls_alert, {alert, _text}}), do: "TLS: #{alert}"
  defp describe_error({reason, :undefined}) when is_atom(reason), do: describe_error(reason)
  defp describe_error(:econnrefused), do: "connection refused"
  defp describe_error(:nxdomain), do: "unknown host"
  defp describe_error(:timeout), do: "timeout"
  defp describe_error(:ssl_closed), do: "connection closed"
  defp describe_error(:tcp_closed), do: "connection closed"
  defp describe_error(:unauthorized_client), do: "not authorised (user name or password)"
  defp describe_error(:bad_username_or_password), do: "not authorised (user name or password)"
  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  defp random_suffix do
    alphabet = ~c"abcdefghijklmnopqrstuvwxyz0123456789"
    for _ <- 1..8, into: "", do: <<Enum.random(alphabet)>>
  end
end
