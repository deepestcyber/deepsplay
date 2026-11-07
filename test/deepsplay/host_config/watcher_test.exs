defmodule Deepsplay.HostConfig.WatcherTest do
  # Not async: replaces the global host configuration, secrets and file paths.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.HostConfig.Watcher
  alias Deepsplay.Secrets

  @moduletag :tmp_dir

  defp config(tmp_dir, extra \\ "", server_extra \\ "") do
    """
    [server]
    cache_dir      = "#{tmp_dir}/cache"
    default_config = "lobby"
    #{server_extra}

    [[config]]
    name = "lobby"
    path = "#{tmp_dir}/lobby"
    #{extra}
    """
  end

  setup %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "host.toml")
    secrets_path = Path.join(tmp_dir, "secrets.toml")
    File.write!(config_path, config(tmp_dir))
    File.write!(secrets_path, ~s(token = "a"\n))
    File.chmod!(secrets_path, 0o600)

    previous =
      {Store.get(), Application.get_env(:deepsplay, :host_config_path),
       Application.get_env(:deepsplay, :secrets_path)}

    Application.put_env(:deepsplay, :host_config_path, config_path)
    Application.put_env(:deepsplay, :secrets_path, secrets_path)
    Store.load()

    on_exit(fn ->
      {store, config_env, secrets_env} = previous
      Store.put(store)
      Secrets.put(%{})
      Application.put_env(:deepsplay, :host_config_path, config_env)
      Application.put_env(:deepsplay, :secrets_path, secrets_env)
    end)

    watcher = start_supervised!({Watcher, name: :test_watcher, interval: 60_000, signals: false})
    Watcher.subscribe()
    %{config_path: config_path, secrets_path: secrets_path, watcher: watcher}
  end

  test "applies a valid change and reports it", ctx do
    File.write!(
      ctx.config_path,
      config(ctx.tmp_dir, """
      description = "Entrance"

      [[config]]
      name = "kitchen"
      path = "#{ctx.tmp_dir}/kitchen"
      """)
    )

    :ok = Watcher.check_now(ctx.watcher)

    assert {:ok, host_config} = Store.get()
    assert Map.keys(host_config.configs) == ["kitchen", "lobby"]
    assert_received {:host_config_changed}

    info = Watcher.info(ctx.watcher)
    assert info.changes == ["configuration added: kitchen", "configuration changed: lobby"]
    assert info.rejected == nil
    assert info.restart_needed == []
  end

  test "does nothing while the files are unchanged", ctx do
    :ok = Watcher.check_now(ctx.watcher)
    refute_received {:host_config_changed}
    assert Watcher.info(ctx.watcher).changes == []
  end

  test "keeps the last good version when a change is invalid, until fixed", ctx do
    File.write!(ctx.config_path, "[server]\ncache_dir = ")

    log = capture_log(fn -> :ok = Watcher.check_now(ctx.watcher) end)
    assert log =~ "changed host configuration rejected"

    assert {:ok, %{configs: %{"lobby" => _}}} = Store.get()
    assert %{rejected: %{errors: [_ | _]}} = Watcher.info(ctx.watcher)
    assert_received {:host_config_changed}

    # Unchanged broken file: not reported again.
    log = capture_log(fn -> :ok = Watcher.check_now(ctx.watcher) end)
    refute log =~ "rejected"

    File.write!(ctx.config_path, config(ctx.tmp_dir))
    :ok = Watcher.check_now(ctx.watcher)
    assert Watcher.info(ctx.watcher).rejected == nil
  end

  test "an invalid secrets file rejects the change and keeps the secrets", ctx do
    File.write!(ctx.secrets_path, "token = 3\n")
    capture_log(fn -> :ok = Watcher.check_now(ctx.watcher) end)

    assert Secrets.fetch("token") == {:ok, "a"}
    assert %{rejected: %{errors: [_]}} = Watcher.info(ctx.watcher)
  end

  test "reports changed secrets without showing them", ctx do
    File.write!(ctx.secrets_path, ~s(token = "b"\n))
    :ok = Watcher.check_now(ctx.watcher)

    assert Secrets.fetch("token") == {:ok, "b"}
    assert Watcher.info(ctx.watcher).changes == ["secrets changed"]
  end

  test "reports directories that need a restart", ctx do
    File.write!(ctx.config_path, config(ctx.tmp_dir, "", ~s(state_dir = "#{ctx.tmp_dir}/state")))
    :ok = Watcher.check_now(ctx.watcher)

    info = Watcher.info(ctx.watcher)
    assert info.changes == ["server settings changed: state_dir"]
    assert info.restart_needed == ["state_dir"]
  end

  test "applies a new cache size", ctx do
    File.write!(ctx.config_path, config(ctx.tmp_dir, "", ~s(upstream_cache_size = "50MB")))
    :ok = Watcher.check_now(ctx.watcher)

    assert Deepsplay.UpstreamProxy.Cache.size().max_size == 50_000_000
    Deepsplay.UpstreamProxy.Cache.set_max_size(200_000_000)
  end

  test "SIGHUP checks at once", ctx do
    stop_supervised!(Watcher)
    start_supervised!({Watcher, name: :test_watcher, interval: 60_000, signals: true})

    File.write!(ctx.secrets_path, ~s(token = "c"\n))
    # What the Erlang signal server does on SIGHUP.
    :gen_event.notify(:erl_signal_server, :sighup)

    assert_receive {:host_config_changed}, 2_000
    assert Secrets.fetch("token") == {:ok, "c"}
  end
end
