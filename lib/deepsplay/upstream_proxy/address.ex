defmodule Deepsplay.UpstreamProxy.Address do
  @moduledoc """
  Checks where a request to an upstream declared in a manifest may go
  (ADR 19): the host name is resolved to all its addresses, and the request
  is refused if any of them is not public (loopback, private, link-local,
  unique-local, documentation, multicast and similar ranges). The proxy then
  connects to a checked address, so neither the URL nor DNS can reach the
  internal network.

  Resolution uses the system resolver; tests replace it with the
  `:proxy_resolver` application setting, a function from host name to a list
  of addresses.
  """

  import Bitwise

  @type ip :: :inet.ip_address()

  @v4_blocked [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @v6_blocked [
    # unspecified, loopback and other embedded IPv4 forms; discard; IETF
    # assignments (Teredo etc.)
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    # 6to4
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    # unique local, link-local, multicast
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc """
  Resolves `host` (a name or an IP literal) to the address to connect to.
  IPv4 addresses are preferred.
  """
  @spec resolve(String.t()) :: {:ok, ip()} | {:error, String.t()}
  def resolve(host) do
    addresses =
      case :inet.parse_strict_address(String.to_charlist(String.trim(host, "[]"))) do
        {:ok, ip} -> [ip]
        {:error, _not_literal} -> resolver().(host)
      end

    cond do
      addresses == [] -> {:error, ~s(cannot resolve "#{host}")}
      not Enum.all?(addresses, &public?/1) -> {:error, ~s("#{host}" has a non-public address)}
      true -> {:ok, Enum.min_by(addresses, &tuple_size/1)}
    end
  end

  @doc """
  Formats an address for a URL host.
  """
  @spec to_host(ip()) :: String.t()
  def to_host(ip), do: ip |> :inet.ntoa() |> to_string()

  defp resolver, do: Application.get_env(:deepsplay, :proxy_resolver, &system_resolve/1)

  defp system_resolve(host) do
    name = String.to_charlist(host)

    for family <- [:inet, :inet6],
        {:ok, addresses} <- [:inet.getaddrs(name, family)],
        address <- addresses,
        do: address
  end

  @doc """
  Returns true for a public unicast address.

      iex> Deepsplay.UpstreamProxy.Address.public?({93, 184, 216, 34})
      true

      iex> Deepsplay.UpstreamProxy.Address.public?({192, 168, 1, 1})
      false

      iex> Deepsplay.UpstreamProxy.Address.public?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      false
  """
  @spec public?(ip()) :: boolean()
  def public?({_, _, _, _} = ip), do: not Enum.any?(@v4_blocked, &in_block?(ip, &1))

  # IPv4 mapped and NAT64 addresses are judged by the IPv4 address in them.
  def public?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: public?(v4(high, low))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: public?(v4(high, low))

  def public?({_, _, _, _, _, _, _, _} = ip), do: not Enum.any?(@v6_blocked, &in_block?(ip, &1))

  defp v4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp in_block?(ip, {base, bits}) when tuple_size(ip) == tuple_size(base) do
    width = if tuple_size(ip) == 4, do: 8, else: 16
    total = tuple_size(ip) * width
    shift = total - bits
    to_int(ip, width) >>> shift == to_int(base, width) >>> shift
  end

  defp in_block?(_ip, _block), do: false

  defp to_int(ip, width) do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)
  end
end
