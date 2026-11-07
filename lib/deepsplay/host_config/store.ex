defmodule Deepsplay.HostConfig.Store do
  @moduledoc """
  Holds the host configuration, loaded at startup and replaced when a changed
  version is valid (`Deepsplay.HostConfig.Watcher`, ADR 23).

  A missing or invalid host configuration does not stop the application: the
  errors are kept here and every screen shows them on the fallback page.
  """

  require Logger

  alias Deepsplay.HostConfig
  alias Deepsplay.HostConfig.Config
  alias Deepsplay.Secrets

  @key {__MODULE__, :host_config}

  @type state :: {:ok, HostConfig.t()} | {:error, [String.t()]}

  @doc """
  Loads the secrets and then the host configuration from the
  `:host_config_path` application setting, and stores the result. Unusable
  secrets make the host configuration unusable too.
  """
  @spec load() :: state()
  def load do
    result =
      case read() do
        {:ok, host_config, secrets} ->
          Secrets.put(secrets)
          {:ok, host_config}

        {:error, errors} ->
          Secrets.put(%{})
          {:error, errors}
      end

    case result do
      {:ok, _config} ->
        :ok

      {:error, errors} ->
        Logger.error("host configuration unusable:\n  " <> Enum.join(errors, "\n  "))
    end

    put(result)
  end

  @doc """
  Reads the secrets and the host configuration without storing anything, so a
  reload (ADR 23) can check a new version before applying it.
  """
  @spec read() :: {:ok, HostConfig.t(), %{String.t() => String.t()}} | {:error, [String.t()]}
  def read do
    # Secrets first: the host configuration refers to them by name (ADR 8).
    with {:ok, secrets} <- Secrets.read() do
      case Application.get_env(:deepsplay, :host_config_path) do
        nil ->
          {:error, ["no host configuration: DEEPSPLAY_CONFIG is not set"]}

        path ->
          with {:ok, host_config} <- HostConfig.load(path, secrets: Map.keys(secrets)),
               do: {:ok, host_config, secrets}
      end
    end
  end

  @doc """
  Stores a host configuration result.
  """
  @spec put(state()) :: state()
  def put(state) do
    :persistent_term.put(@key, state)
    state
  end

  @doc """
  Returns the stored host configuration result.
  """
  @spec get() :: state()
  def get do
    :persistent_term.get(@key, {:error, ["host configuration not loaded"]})
  end

  @doc """
  Looks up a configuration by name, or the default one with `:default`.
  """
  @spec lookup(String.t() | :default) ::
          {:ok, Config.t()} | {:error, :unknown_config} | {:error, {:host_config, [String.t()]}}
  def lookup(name) do
    case get() do
      {:ok, host_config} ->
        name = if name == :default, do: host_config.default_config, else: name

        case Map.fetch(host_config.configs, name) do
          {:ok, config} -> {:ok, config}
          :error -> {:error, :unknown_config}
        end

      {:error, errors} ->
        {:error, {:host_config, errors}}
    end
  end
end
