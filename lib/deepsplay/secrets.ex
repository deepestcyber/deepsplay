defmodule Deepsplay.Secrets do
  @moduledoc """
  Host secrets (ADR 8): values used by the server on a page's behalf, never
  part of a repository and never sent to the browser.

  Secrets come from two places, read at startup and again when the host
  configuration is reloaded (ADR 23):

    * a TOML file of `name = "value"` pairs, at the `:secrets_path` setting
      (`DEEPSPLAY_SECRETS`); it should be readable by its owner only
    * environment variables `DEEPSPLAY_SECRET_<NAME>`, e.g.
      `DEEPSPLAY_SECRET_WEATHER_API` for `weather_api`; these win over the file

  Names are lowercase letters, digits and `_`. Values are never logged or
  shown; only names are.
  """

  require Logger

  @key {__MODULE__, :secrets}
  @env_prefix "DEEPSPLAY_SECRET_"
  @name ~r/^[a-z][a-z0-9_]*$/

  @doc """
  Loads secrets from the configured file and the environment, and stores them.
  Returns the names, or the problems found.
  """
  @spec load() :: {:ok, [String.t()]} | {:error, [String.t()]}
  def load do
    case read() do
      {:ok, secrets} ->
        put(secrets)
        {:ok, names()}

      {:error, errors} ->
        put(%{})
        {:error, errors}
    end
  end

  @doc """
  Reads secrets from the configured file and the environment without storing
  them, so a reload can check them first.
  """
  @spec read() :: {:ok, %{String.t() => String.t()}} | {:error, [String.t()]}
  def read do
    with {:ok, from_file} <- read_file(Application.get_env(:deepsplay, :secrets_path)) do
      {:ok, Map.merge(from_file, from_env(System.get_env()))}
    end
  end

  @doc """
  Parses secrets from a TOML string.
  """
  @spec parse(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, [String.t()]}
  def parse(toml) do
    case TomlElixir.decode(toml) do
      {:ok, data} ->
        errors =
          for {name, value} <- data, not (Regex.match?(@name, name) and is_binary(value)) do
            ~s(secret "#{name}" must have a lowercase name and a string value)
          end

        if errors == [], do: {:ok, data}, else: {:error, Enum.sort(errors)}

      {:error, error} ->
        {:error, ["secrets file is invalid TOML: #{Exception.message(error)}"]}
    end
  end

  @doc """
  Reads secrets from environment variables `DEEPSPLAY_SECRET_<NAME>`.
  """
  @spec from_env(%{String.t() => String.t()}) :: %{String.t() => String.t()}
  def from_env(env) do
    for {key, value} <- env,
        String.starts_with?(key, @env_prefix),
        name = key |> String.replace_prefix(@env_prefix, "") |> String.downcase(),
        Regex.match?(@name, name),
        into: %{},
        do: {name, value}
  end

  @doc """
  Stores secrets (after `read/0`, or directly in tests).
  """
  @spec put(%{String.t() => String.t()}) :: :ok
  def put(secrets), do: :persistent_term.put(@key, secrets)

  @doc """
  Returns the value of a secret.
  """
  @spec fetch(String.t()) :: {:ok, String.t()} | :error
  def fetch(name), do: Map.fetch(all(), name)

  @doc """
  Returns the names of all secrets.
  """
  @spec names() :: [String.t()]
  def names, do: all() |> Map.keys() |> Enum.sort()

  @doc """
  Replaces `{secret:name}` in a template with the secret's value.
  """
  @spec expand(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def expand(template) do
    Regex.split(~r/\{secret:([a-z][a-z0-9_]*)\}/, template, include_captures: true)
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, acc} ->
      case Regex.run(~r/^\{secret:([a-z][a-z0-9_]*)\}$/, part) do
        [_, name] ->
          case fetch(name) do
            {:ok, value} -> {:cont, {:ok, acc <> value}}
            :error -> {:halt, {:error, ~s(secret "#{name}" is not defined)}}
          end

        nil ->
          {:cont, {:ok, acc <> part}}
      end
    end)
  end

  @doc """
  Returns the secret names a template refers to.
  """
  @spec references(String.t()) :: [String.t()]
  def references(template) do
    for [_, name] <- Regex.scan(~r/\{secret:([a-z][a-z0-9_]*)\}/, template), do: name
  end

  defp all, do: :persistent_term.get(@key, %{})

  defp read_file(nil), do: {:ok, %{}}

  defp read_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        if Bitwise.band(mode, 0o077) != 0 do
          Logger.warning("secrets file #{path} is readable by others; use mode 0600")
        end

        case File.read(path) do
          {:ok, toml} -> parse(toml)
          {:error, reason} -> {:error, ["cannot read #{path}: #{:file.format_error(reason)}"]}
        end

      {:error, reason} ->
        {:error, ["cannot read #{path}: #{:file.format_error(reason)}"]}
    end
  end
end
