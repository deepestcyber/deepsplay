defmodule Deepsplay.HostConfig.Mqtt do
  @moduledoc """
  The MQTT broker of the host configuration (`[mqtt]`, ADR 33): where
  deepsplay connects to receive interrupts.

  `tls` is true for `mqtts://` URLs. `password_secret` names the secret
  that holds the password (`password = "{secret:<name>}"` in the file).
  `client_id` is `nil` unless set; the connection then makes one at start.
  `ca_file` is the expanded path of a CA certificate file, or `nil` for the
  system's CA certificates.
  """

  @enforce_keys [:host, :port, :tls]
  defstruct [:host, :port, :tls, :username, :password_secret, :client_id, :ca_file]

  @type t :: %__MODULE__{
          host: String.t(),
          port: pos_integer(),
          tls: boolean(),
          username: String.t() | nil,
          password_secret: String.t() | nil,
          client_id: String.t() | nil,
          ca_file: String.t() | nil
        }

  @doc """
  Parses the broker URL into host, port and whether TLS is used.

      iex> Deepsplay.HostConfig.Mqtt.cast_url("mqtts://broker.example.org")
      {:ok, %{host: "broker.example.org", port: 8883, tls: true}}

      iex> Deepsplay.HostConfig.Mqtt.cast_url("mqtt://localhost:1884")
      {:ok, %{host: "localhost", port: 1884, tls: false}}

      iex> Deepsplay.HostConfig.Mqtt.cast_url("https://broker.example.org")
      {:error, "must be an mqtts:// or mqtt:// URL with a host and an optional port"}
  """
  @spec cast_url(term()) :: {:ok, map()} | {:error, String.t()}
  def cast_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port, userinfo: nil, query: nil, fragment: nil} = uri
      when scheme in ["mqtt", "mqtts"] and is_binary(host) and host != "" and
             uri.path in [nil, "", "/"] ->
        tls = scheme == "mqtts"
        {:ok, %{host: host, port: port || default_port(tls), tls: tls}}

      _other ->
        {:error, "must be an mqtts:// or mqtt:// URL with a host and an optional port"}
    end
  end

  def cast_url(_value), do: {:error, "must be a string"}

  defp default_port(true), do: 8883
  defp default_port(false), do: 1883

  @doc """
  Returns the secret name of a password template that is exactly one
  `{secret:<name>}` reference.

      iex> Deepsplay.HostConfig.Mqtt.cast_password("{secret:mqtt_password}")
      {:ok, "mqtt_password"}

      iex> Deepsplay.HostConfig.Mqtt.cast_password("hunter2")
      {:error, ~s(must be a secret reference like "{secret:mqtt_password}", not the password itself)}
  """
  @spec cast_password(term()) :: {:ok, String.t()} | {:error, String.t()}
  def cast_password(value) when is_binary(value) do
    case Regex.run(~r/^\{secret:([a-z][a-z0-9_]*)\}$/, value) do
      [_, name] ->
        {:ok, name}

      nil ->
        {:error,
         ~s(must be a secret reference like "{secret:mqtt_password}", not the password itself)}
    end
  end

  def cast_password(_value), do: {:error, "must be a string"}

  @doc """
  Checks a client identifier: 1 to 23 characters of letters, digits, `-`
  and `_`, which every MQTT 3.1.1 broker accepts.
  """
  @spec cast_client_id(term()) :: {:ok, String.t()} | {:error, String.t()}
  def cast_client_id(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9_-]{1,23}$/, value),
      do: {:ok, value},
      else: {:error, ~s(must be 1 to 23 characters of letters, digits, "-" and "_")}
  end

  def cast_client_id(_value), do: {:error, "must be a string"}

  @doc """
  Checks a CA certificate file: it must exist and be readable. Returns the
  expanded path.
  """
  @spec cast_ca_file(term()) :: {:ok, String.t()} | {:error, String.t()}
  def cast_ca_file(value) when is_binary(value) and value != "" do
    path = Path.expand(value)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write] ->
        {:ok, path}

      {:ok, _not_a_readable_file} ->
        {:error, "must be a readable file"}

      {:error, reason} ->
        {:error, "cannot be read: #{:file.format_error(reason)}"}
    end
  end

  def cast_ca_file(_value), do: {:error, "must be a non-empty string"}

  @doc """
  Checks the topic filter of a configuration (`mqtt_topic`): levels
  separated by `/`, each non-empty or `+`, the last one `+` (the name of the
  interrupt), no `#`, not starting with `$`, at most 256 characters.

      iex> Deepsplay.HostConfig.Mqtt.cast_topic_filter("deepcyber/+/interrupts/+")
      {:ok, "deepcyber/+/interrupts/+"}

      iex> Deepsplay.HostConfig.Mqtt.cast_topic_filter("deepcyber/interrupts/#")
      {:error, ~s(must be a topic filter ending in "/+", without "#")}
  """
  @spec cast_topic_filter(term()) :: {:ok, String.t()} | {:error, String.t()}
  def cast_topic_filter(value) when is_binary(value) do
    levels = String.split(value, "/")

    valid =
      byte_size(value) <= 256 and length(levels) >= 2 and List.last(levels) == "+" and
        not String.starts_with?(value, "$") and String.valid?(value) and
        Enum.all?(levels, &filter_level?/1)

    if valid,
      do: {:ok, value},
      else: {:error, ~s(must be a topic filter ending in "/+", without "#")}
  end

  def cast_topic_filter(_value), do: {:error, "must be a string"}

  defp filter_level?("+"), do: true

  defp filter_level?(level),
    do: level != "" and not String.contains?(level, ["+", "#", <<0>>])
end
