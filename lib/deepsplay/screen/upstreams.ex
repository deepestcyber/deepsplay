defmodule Deepsplay.Screen.Upstreams do
  @moduledoc """
  Upstreams declared in a manifest (ADR 19): open APIs without secrets, used
  through the upstream proxy and its cache like host upstreams.

      [upstream.radar]
      url       = "https://maps.dwd.de/geoserver/dwd/wms"
      cache_ttl = "5m"

  Allowed keys: `url` (`https` only), `cache_ttl` (required, at least one
  minute), `stale_ttl`, `refresh`, `timeout` and `accepted_types` (ADR 22). The host decides whether a
  configuration accepts them, and for which hosts.
  """

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Upstream
  alias Deepsplay.TomlSchema

  @min_cache_ttl 60_000

  @fields [
    {"url", :base_url, &__MODULE__.cast_url/1, []},
    {"cache_ttl", :cache_ttl, :duration, []},
    {"stale_ttl", :stale_ttl, :duration, default: nil},
    {"refresh", :refresh, :boolean, default: false},
    {"accepted_types", :accepted_types, &Upstream.cast_accepted_types/1, default: nil},
    {"timeout", :timeout, :duration, default: 15_000}
  ]

  @doc """
  Reads the `[upstream]` table of a manifest for `config`.
  """
  @spec parse(term(), Config.t()) :: {%{String.t() => Upstream.t()}, [String.t()]}
  def parse(nil, _config), do: {%{}, []}

  def parse(table, %Config{repo_upstreams: false}) when is_map(table) and table != %{},
    do: {%{}, ["upstreams in the manifest are not allowed for this configuration"]}

  def parse(table, config) when is_map(table) do
    {upstreams, errors} =
      table
      |> Enum.sort()
      |> Enum.map_reduce([], fn {name, entry}, acc ->
        {upstream, errors} = upstream(name, entry, config)
        {upstream, acc ++ errors}
      end)

    {Map.new(for %Upstream{} = upstream <- upstreams, do: {upstream.name, upstream}), errors}
  end

  def parse(_table, _config), do: {%{}, ["upstream must be a table"]}

  defp upstream(name, entry, config) when is_map(entry) do
    ctx = "upstream.#{name}"
    {fields, errors} = TomlSchema.fields(entry, ctx, @fields)

    errors =
      errors ++
        name_errors(name, ctx, config) ++
        ttl_errors(fields.cache_ttl, ctx) ++
        host_errors(fields.base_url, ctx, config)

    case errors do
      [] ->
        {struct!(Upstream, Map.merge(fields, %{name: name, origin: :manifest})), []}

      errors ->
        {nil, errors}
    end
  end

  defp upstream(name, _entry, _config), do: {nil, ["upstream.#{name} must be a table"]}

  defp name_errors(name, ctx, config) do
    cond do
      not Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, name) ->
        [~s(#{ctx}: name must be lowercase letters, digits, "-" and "_")]

      name in config.upstreams ->
        ["#{ctx}: an upstream of the host configuration has this name"]

      true ->
        []
    end
  end

  defp ttl_errors(ttl, ctx) when is_integer(ttl) and ttl < @min_cache_ttl,
    do: ["#{ctx}.cache_ttl must be at least 1m"]

  defp ttl_errors(_ttl, _ctx), do: []

  defp host_errors(nil, _ctx, _config), do: []

  defp host_errors(url, ctx, config) do
    host = URI.parse(url).host

    if Config.repo_upstream_host?(config, host),
      do: [],
      else: [~s(#{ctx}.url: host "#{host}" is not allowed for this configuration)]
  end

  @doc false
  def cast_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, query: nil, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(value, "/")}

      _other ->
        {:error, "must be an https URL without credentials, query or fragment"}
    end
  end

  def cast_url(_value), do: {:error, "must be a string"}
end
