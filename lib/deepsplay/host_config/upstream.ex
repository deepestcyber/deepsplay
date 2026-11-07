defmodule Deepsplay.HostConfig.Upstream do
  @moduledoc """
  A named upstream of the host configuration (ADR 8): where the proxy forwards
  page requests, and how it adds a secret to them.

  `value` and `query_value` are templates; `{secret:name}` is replaced by the
  secret's value when a request is forwarded.

  `accepted_types` lists the content types accepted as successful answers
  (ADR 22), lowercase; see `accepts?/2`. `cache_size` limits the upstream's
  share of the cache (ADR 22).

  Upstreams declared in a manifest (ADR 19) use the same struct with
  `origin: :manifest`: no secrets, `GET` only.
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
    :stale_ttl,
    :accepted_types,
    :cache_size,
    :description,
    methods: ["GET"],
    refresh: false,
    origin: :host,
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
          stale_ttl: pos_integer() | nil,
          accepted_types: [String.t()] | nil,
          cache_size: pos_integer() | nil,
          description: String.t() | nil,
          refresh: boolean(),
          origin: :host | :manifest,
          timeout: pos_integer()
        }

  @doc """
  Casts `accepted_types`: a non-empty list of media types (`type/subtype`)
  or families (`type/*`), without parameters.
  """
  @spec cast_accepted_types(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def cast_accepted_types(value) when is_list(value) and value != [] do
    if Enum.all?(value, &media_type?/1),
      do: {:ok, Enum.map(value, &String.downcase/1)},
      else: {:error, ~s(must be a list of media types such as "image/png" or "image/*")}
  end

  def cast_accepted_types(_value),
    do: {:error, ~s(must be a list of media types such as "image/png" or "image/*")}

  defp media_type?(value) when is_binary(value),
    do:
      Regex.match?(
        ~r{^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/([A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*|\*)$},
        value
      )

  defp media_type?(_value), do: false

  @doc """
  Returns true if an answer with this `Content-Type` (or `nil` for none) is
  accepted by the upstream (ADR 22). Without `accepted_types` every answer is.

      iex> upstream = %Deepsplay.HostConfig.Upstream{name: "radar", base_url: "https://x", accepted_types: ["image/png", "text/*"]}
      iex> Deepsplay.HostConfig.Upstream.accepts?(upstream, "Image/PNG; charset=binary")
      true
      iex> Deepsplay.HostConfig.Upstream.accepts?(upstream, "text/xml;charset=UTF-8")
      true
      iex> Deepsplay.HostConfig.Upstream.accepts?(upstream, "application/xml")
      false
      iex> Deepsplay.HostConfig.Upstream.accepts?(upstream, nil)
      false
  """
  @spec accepts?(t(), String.t() | nil) :: boolean()
  def accepts?(%__MODULE__{accepted_types: nil}, _content_type), do: true
  def accepts?(_upstream, nil), do: false

  def accepts?(%__MODULE__{accepted_types: types}, content_type) do
    type =
      content_type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    family = (type |> String.split("/", parts: 2) |> hd()) <> "/*"
    type in types or family in types
  end
end
