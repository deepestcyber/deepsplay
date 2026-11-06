defmodule Deepsplay.HostConfig.StoreTest do
  # Not async: the store and the application environment are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Store

  setup do
    previous_state = Store.get()
    previous_path = Application.get_env(:deepsplay, :host_config_path)

    on_exit(fn ->
      Store.put(previous_state)
      Application.put_env(:deepsplay, :host_config_path, previous_path)
    end)
  end

  test "load/0 loads the configured file" do
    assert {:ok, %HostConfig{default_config: "lobby"}} = Store.load()
    assert {:ok, %{name: "lobby"}} = Store.lookup(:default)
    assert {:ok, %{name: "kitchen"}} = Store.lookup("kitchen")
    assert {:error, :unknown_config} = Store.lookup("nowhere")
  end

  test "load/0 keeps and logs errors instead of failing" do
    Application.put_env(:deepsplay, :host_config_path, "/nonexistent/host.toml")

    log = capture_log(fn -> assert {:error, [_]} = Store.load() end)

    assert log =~ "host configuration unusable"
    assert {:error, {:host_config, [error]}} = Store.lookup(:default)
    assert error =~ "/nonexistent/host.toml"
  end

  test "load/0 reports a missing DEEPSPLAY_CONFIG" do
    Application.delete_env(:deepsplay, :host_config_path)

    capture_log(fn -> Store.load() end)

    assert {:error, {:host_config, ["no host configuration: DEEPSPLAY_CONFIG is not set"]}} =
             Store.lookup("lobby")
  end
end
