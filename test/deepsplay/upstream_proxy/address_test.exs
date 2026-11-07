defmodule Deepsplay.UpstreamProxy.AddressTest do
  use ExUnit.Case, async: true

  alias Deepsplay.UpstreamProxy.Address

  doctest Address

  test "public and non-public addresses" do
    public = [
      {93, 184, 216, 34},
      {8, 8, 8, 8},
      {0x2A00, 0x1450, 0x4001, 0x80E, 0, 0, 0, 0x200E},
      {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808}
    ]

    non_public = [
      {0, 0, 0, 0},
      {10, 1, 2, 3},
      {100, 64, 0, 1},
      {127, 0, 0, 1},
      {169, 254, 169, 254},
      {172, 16, 0, 1},
      {172, 31, 255, 255},
      {192, 168, 178, 1},
      {224, 0, 0, 1},
      {255, 255, 255, 255},
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
      {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001},
      {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
      {0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 1}
    ]

    for ip <- public, do: assert(Address.public?(ip), inspect(ip))
    for ip <- non_public, do: refute(Address.public?(ip), inspect(ip))
    assert Address.public?({172, 15, 0, 1})
  end

  test "resolves literals and refuses non-public ones" do
    assert Address.resolve("93.184.216.34") == {:ok, {93, 184, 216, 34}}
    assert {:error, _} = Address.resolve("127.0.0.1")
    assert {:error, _} = Address.resolve("[::1]")
  end

  test "refuses names with any non-public address, preferring IPv4" do
    # The test resolver (config/test.exs) knows these names.
    assert Address.resolve("public.example.com") == {:ok, {93, 184, 216, 34}}
    assert {:error, message} = Address.resolve("mixed.example.com")
    assert message =~ "non-public address"
    assert {:error, "cannot resolve" <> _} = Address.resolve("unknown.example.com")
  end

  test "formats addresses for URLs" do
    assert Address.to_host({93, 184, 216, 34}) == "93.184.216.34"
    assert Address.to_host({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == "2001:db8::1"
  end
end
