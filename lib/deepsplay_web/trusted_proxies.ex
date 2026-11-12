defmodule DeepsplayWeb.TrustedProxies do
  @moduledoc """
  Takes the scheme of a request from `X-Forwarded-Proto`, with the scheme's
  default port, and the client address from `X-Forwarded-For`, but only when
  the request comes from a trusted reverse proxy (ADR 34).

  The proxies are set with `DEEPSPLAY_TRUSTED_PROXIES`: IP addresses or CIDR
  ranges, separated by commas. Without it, no header is trusted and requests
  keep the scheme, port and address they arrived with.

  The host and port are never taken from a header: proxies such as Caddy pass
  the `Host` header on unchanged, but pass a client's `X-Forwarded-Port` on
  as well.

  The rewrite runs in `DeepsplayWeb.Endpoint.call/2`, before the socket
  dispatch, so the origin check of the LiveView socket (`check_origin: :conn`)
  compares the browser's origin with the scheme and port the browser used.
  """

  import Bitwise

  @key {__MODULE__, :proxies}

  @type range :: {:inet.ip_address(), 0..128}

  @doc """
  Parses a list of IP addresses and CIDR ranges.

      iex> DeepsplayWeb.TrustedProxies.parse("10.0.0.2, 192.168.1.0/24, ::1")
      {:ok, [{{10, 0, 0, 2}, 32}, {{192, 168, 1, 0}, 24}, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}]}

      iex> DeepsplayWeb.TrustedProxies.parse(nil)
      {:ok, []}

      iex> DeepsplayWeb.TrustedProxies.parse("10.0.0.300")
      {:error, ~s(DEEPSPLAY_TRUSTED_PROXIES: "10.0.0.300" is not an IP address or CIDR range)}
  """
  @spec parse(String.t() | nil) :: {:ok, [range()]} | {:error, String.t()}
  def parse(nil), do: {:ok, []}

  def parse(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_range(entry) do
        {:ok, range} ->
          {:cont, {:ok, [range | acc]}}

        :error ->
          {:halt,
           {:error, ~s(DEEPSPLAY_TRUSTED_PROXIES: "#{entry}" is not an IP address or CIDR range)}}
      end
    end)
    |> case do
      {:ok, ranges} -> {:ok, Enum.reverse(ranges)}
      error -> error
    end
  end

  defp parse_range(entry) do
    {address, bits} =
      case String.split(entry, "/", parts: 2) do
        [address] -> {address, nil}
        [address, bits] -> {address, bits}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         ip = normalize(ip),
         size = size(ip),
         {:ok, bits} <- parse_bits(bits, size) do
      {:ok, {ip, bits}}
    else
      _error -> :error
    end
  end

  defp parse_bits(nil, size), do: {:ok, size}

  defp parse_bits(bits, size) do
    case Integer.parse(bits) do
      {n, ""} when n >= 0 and n <= size -> {:ok, n}
      _other -> :error
    end
  end

  @doc """
  Parses `value` and stores the ranges for `rewrite/1`. Raises on an invalid
  value, so a typo does not silently trust nobody.
  """
  @spec setup!(String.t() | nil) :: :ok
  def setup!(value) do
    case parse(value) do
      {:ok, ranges} -> :persistent_term.put(@key, ranges)
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "The stored ranges."
  @spec ranges() :: [range()]
  def ranges, do: :persistent_term.get(@key, [])

  @doc """
  Whether `ip` is in one of `ranges`.

      iex> ranges = [{{10, 0, 0, 0}, 8}, {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}]
      iex> DeepsplayWeb.TrustedProxies.trusted?({10, 1, 2, 3}, ranges)
      true
      iex> DeepsplayWeb.TrustedProxies.trusted?({0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203}, ranges)
      true
      iex> DeepsplayWeb.TrustedProxies.trusted?({11, 0, 0, 1}, ranges)
      false
      iex> DeepsplayWeb.TrustedProxies.trusted?({0xFD12, 0, 0, 0, 0, 0, 0, 1}, ranges)
      true
  """
  @spec trusted?(:inet.ip_address(), [range()]) :: boolean()
  def trusted?(ip, ranges) do
    ip = normalize(ip)
    size = size(ip)

    Enum.any?(ranges, fn {network, bits} ->
      size(network) == size and
        to_integer(ip) >>> (size - bits) == to_integer(network) >>> (size - bits)
    end)
  end

  @doc """
  The client address for a connection from `peer` with the given
  `X-Forwarded-For` header values.

  Only a trusted `peer` is believed. The list is read from the right, the
  entries the nearest proxies added: trusted proxies are skipped, the first
  address that is not trusted is the client. Entries further left were
  written by the client itself and are ignored. An invalid entry stops the
  search at the last good address; if all are trusted, the leftmost wins.

      iex> ranges = [{{10, 0, 0, 2}, 32}]
      iex> DeepsplayWeb.TrustedProxies.client_ip({10, 0, 0, 2}, ["6.6.6.6, 192.168.1.20"], ranges)
      {192, 168, 1, 20}
      iex> DeepsplayWeb.TrustedProxies.client_ip({10, 0, 0, 3}, ["192.168.1.20"], ranges)
      {10, 0, 0, 3}
      iex> DeepsplayWeb.TrustedProxies.client_ip({10, 0, 0, 2}, [], ranges)
      {10, 0, 0, 2}
  """
  @spec client_ip(:inet.ip_address(), [String.t()], [range()]) :: :inet.ip_address()
  def client_ip(peer, forwarded_for, ranges \\ ranges()) do
    peer = normalize(peer)

    if trusted?(peer, ranges) do
      forwarded_for
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.reduce_while(peer, fn entry, last ->
        case :inet.parse_strict_address(String.to_charlist(entry)) do
          {:ok, ip} ->
            ip = normalize(ip)
            if trusted?(ip, ranges), do: {:cont, ip}, else: {:halt, ip}

          {:error, _reason} ->
            {:halt, last}
        end
      end)
    else
      peer
    end
  end

  @doc """
  Rewrites a request that comes from a trusted proxy: the scheme from
  `X-Forwarded-Proto` (`http` or `https`) with the scheme's default port, and
  `remote_ip` from `X-Forwarded-For` (`client_ip/3`). A missing, repeated or
  invalid `X-Forwarded-Proto` leaves scheme and port as they are.
  """
  @spec rewrite(Plug.Conn.t(), [range()]) :: Plug.Conn.t()
  def rewrite(conn, ranges \\ ranges())

  def rewrite(conn, []), do: conn

  def rewrite(%Plug.Conn{} = conn, ranges) do
    if trusted?(conn.remote_ip, ranges) do
      forwarded_for = Plug.Conn.get_req_header(conn, "x-forwarded-for")
      conn = %{conn | remote_ip: client_ip(conn.remote_ip, forwarded_for, ranges)}

      case forwarded_scheme(conn) do
        {:ok, scheme} -> %{conn | scheme: scheme, port: if(scheme == :https, do: 443, else: 80)}
        :error -> conn
      end
    else
      conn
    end
  end

  defp forwarded_scheme(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-proto") do
      [proto] ->
        case proto |> String.trim() |> String.downcase() do
          "https" -> {:ok, :https}
          "http" -> {:ok, :http}
          _other -> :error
        end

      _none_or_many ->
        :error
    end
  end

  # IPv4 peers on a dual-stack listener arrive as IPv4-mapped IPv6 addresses.
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: {a >>> 8, a &&& 0xFF, b >>> 8, b &&& 0xFF}
  defp normalize(ip), do: ip

  defp size(ip) when tuple_size(ip) == 4, do: 32
  defp size(ip) when tuple_size(ip) == 8, do: 128

  defp to_integer(ip) do
    {bits, width} = if tuple_size(ip) == 4, do: {8, 4}, else: {16, 8}

    Enum.reduce(0..(width - 1), 0, fn i, acc -> acc <<< bits ||| elem(ip, i) end)
  end
end
