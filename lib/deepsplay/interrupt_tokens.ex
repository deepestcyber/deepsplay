defmodule Deepsplay.InterruptTokens do
  @moduledoc """
  Tokens that may trigger the interrupts of a configuration (ADR 32):

    * one per running backend process, created at each start and passed as
      `DEEPSPLAY_TOKEN`; it is registered by the backend's process while the
      OS process runs, and gone with it;
    * the host secret named by the configuration's `interrupt_token`.

  Tokens are compared in constant time.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.Secrets

  @registry __MODULE__.Registry

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "A new random token: 32 bytes, URL-safe base64."
  @spec generate() :: String.t()
  def generate, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  @doc """
  Registers `token` for the configuration `name`, owned by the calling
  process; any token it registered before for `name` is dropped.
  """
  @spec register(String.t(), String.t()) :: :ok
  def register(name, token) do
    unregister(name)
    {:ok, _owner} = Registry.register(@registry, name, token)
    :ok
  end

  @doc "Drops the calling process's token for the configuration `name`."
  @spec unregister(String.t()) :: :ok
  def unregister(name), do: Registry.unregister(@registry, name)

  @doc "Returns true if `token` may trigger interrupts of `config`."
  @spec valid?(Config.t(), String.t() | nil) :: boolean()
  def valid?(_config, token) when not is_binary(token) or token == "", do: false

  def valid?(%Config{} = config, token) do
    backend_tokens = for {_owner, t} <- Registry.lookup(@registry, config.name), do: t
    # Every candidate is compared, so the time does not tell which one matched.
    Enum.reduce(host_token(config) ++ backend_tokens, false, fn candidate, found ->
      Plug.Crypto.secure_compare(candidate, token) or found
    end)
  end

  defp host_token(%Config{interrupt_token: nil}), do: []

  defp host_token(%Config{interrupt_token: secret}) do
    case Secrets.fetch(secret) do
      {:ok, value} when is_binary(value) and value != "" -> [value]
      _missing -> []
    end
  end
end
