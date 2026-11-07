defmodule Deepsplay.HostConfig.Watcher.SignalHandler do
  @moduledoc """
  Forwards `SIGHUP` from the Erlang signal server to the host configuration
  watcher, which then checks its files at once (ADR 23).
  """

  @behaviour :gen_event

  @impl true
  def init(watcher), do: {:ok, watcher}

  @impl true
  def handle_event(:sighup, watcher) do
    send(watcher, :check)
    {:ok, watcher}
  end

  def handle_event(_signal, watcher), do: {:ok, watcher}

  @impl true
  def handle_call(_request, watcher), do: {:ok, :ok, watcher}
end
