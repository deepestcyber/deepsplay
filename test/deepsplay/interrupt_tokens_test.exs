defmodule Deepsplay.InterruptTokensTest do
  # Secrets are global.
  use ExUnit.Case, async: false

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.InterruptTokens
  alias Deepsplay.Secrets

  setup do
    previous = :persistent_term.get({Secrets, :secrets}, %{})
    on_exit(fn -> Secrets.put(previous) end)
    :ok
  end

  test "generate/0 gives a new URL-safe token each time" do
    token = InterruptTokens.generate()
    assert token =~ ~r/^[A-Za-z0-9_-]{43}$/
    assert InterruptTokens.generate() != token
  end

  test "a registered token is valid for its configuration while registered" do
    config = %Config{name: "tokens-a"}
    token = InterruptTokens.generate()
    refute InterruptTokens.valid?(config, token)

    :ok = InterruptTokens.register("tokens-a", token)
    assert InterruptTokens.valid?(config, token)
    refute InterruptTokens.valid?(%Config{name: "tokens-b"}, token)
    refute InterruptTokens.valid?(config, token <> "x")

    # A new token replaces the process's old one.
    newer = InterruptTokens.generate()
    :ok = InterruptTokens.register("tokens-a", newer)
    assert InterruptTokens.valid?(config, newer)
    refute InterruptTokens.valid?(config, token)

    :ok = InterruptTokens.unregister("tokens-a")
    refute InterruptTokens.valid?(config, newer)
  end

  test "a token is gone with the process that registered it" do
    token = InterruptTokens.generate()
    test = self()

    owner =
      spawn(fn ->
        InterruptTokens.register("tokens-c", token)
        send(test, :registered)
        receive do: (:stop -> :ok)
      end)

    assert_receive :registered
    assert InterruptTokens.valid?(%Config{name: "tokens-c"}, token)

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    # The registry drops the entry when it sees the exit.
    _ = :sys.get_state(InterruptTokens.Registry.PIDPartition0)
    refute InterruptTokens.valid?(%Config{name: "tokens-c"}, token)
  end

  test "the host secret named by interrupt_token is valid" do
    Secrets.put(%{"screen_trigger" => "from-the-host", "empty" => ""})

    assert InterruptTokens.valid?(
             %Config{name: "x", interrupt_token: "screen_trigger"},
             "from-the-host"
           )

    refute InterruptTokens.valid?(%Config{name: "x", interrupt_token: "screen_trigger"}, "other")
    refute InterruptTokens.valid?(%Config{name: "x"}, "from-the-host")
    refute InterruptTokens.valid?(%Config{name: "x", interrupt_token: "missing"}, "from-the-host")
    refute InterruptTokens.valid?(%Config{name: "x", interrupt_token: "empty"}, "")
  end

  test "no token is never valid" do
    refute InterruptTokens.valid?(%Config{name: "x"}, nil)
    refute InterruptTokens.valid?(%Config{name: "x"}, "")
  end
end
