defmodule Deepsplay.TestResolver do
  @moduledoc """
  Name resolution for tests of upstreams declared in manifests: names below
  `example.com` resolve to a public address, a few to others.
  """

  def resolve("mixed.example.com"), do: [{93, 184, 216, 34}, {10, 0, 0, 1}]
  def resolve("internal.example.com"), do: [{192, 168, 1, 10}]
  def resolve("unknown.example.com"), do: []

  def resolve(host) do
    if String.ends_with?(host, ".example.com"),
      do: [{0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}, {93, 184, 216, 34}],
      else: []
  end
end
