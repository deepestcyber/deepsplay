defmodule Deepsplay.HostConfig.Upstream do
  @moduledoc """
  A named upstream of the host configuration (ADR 8): where the proxy forwards
  page requests, and how it adds a secret to them.

  `value` and `query_value` are templates; `{secret:name}` is replaced by the
  secret's value when a request is forwarded.
  """

  @enforce_keys [:name, :base_url]
  defstruct [
    :name,
    :base_url,
    :header,
    :value,
    :query,
    :query_value,
    :cache_ttl,
    methods: ["GET"],
    timeout: 15_000
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          base_url: String.t(),
          methods: [String.t()],
          header: String.t() | nil,
          value: String.t() | nil,
          query: String.t() | nil,
          query_value: String.t() | nil,
          cache_ttl: pos_integer() | nil,
          timeout: pos_integer()
        }
end
