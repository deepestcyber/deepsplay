defmodule Deepsplay.UpstreamProxy do
  @moduledoc """
  Forwards page requests to host-defined upstreams, adding secrets on the
  server (ADR 8), and to upstreams declared in manifests, which have no
  secrets and reach only public addresses (ADR 19).

  A page calls `/c/<config>/api/<upstream>/<path>`. The proxy

  - checks that the configuration may use the upstream and the method is
    allowed,
  - joins the path to the upstream's `base_url` (each segment re-encoded, so a
    page can neither leave the base path nor choose another host),
  - forwards only `Accept`, `Accept-Language` and `Content-Type`, never
    cookies or the client's `Authorization`,
  - adds the secret as a header and/or query parameter (a client parameter of
    the same name is dropped),
  - applies the upstream's timeout and a response size limit,
  - caches successful `GET` answers for `cache_ttl`, so many screens share one
    upstream call; concurrent requests for the same answer wait for a single
    fetch (ADR 20),
  - with `refresh`, fetches answers screens still ask for again before they
    expire,
  - with `stale_ttl`, serves an expired answer when the upstream fails
    (timeout, connection error, `429`, `5xx`, or a `200` of a type not in
    `accepted_types`, ADR 22),
  - returns only the status, the body and safe response headers; cacheable
    answers also carry `X-Deepsplay-Cache` (`hit`, `miss` or `stale`) and
    `Age`.

  Secret values never appear in logs, errors or responses.
  """

  require Logger

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Upstream
  alias Deepsplay.Secrets
  alias Deepsplay.Status
  alias Deepsplay.UpstreamProxy.Address
  alias Deepsplay.UpstreamProxy.Cache
  alias Deepsplay.UpstreamProxy.Stats

  @max_body 5 * 1024 * 1024
  @connect_timeout 5_000
  @request_headers ~w(accept accept-language content-type)
  @response_headers ~w(content-type cache-control etag last-modified expires)

  @type response :: %{status: pos_integer(), headers: [{String.t(), String.t()}], body: binary()}

  @doc """
  Forwards a request. `upstreams` is the host configuration's upstream map,
  `declared` the upstreams declared in the configuration's manifest (ADR 19).

  Returns the upstream's response, or `{:error, status, message}` with the
  status to answer the page with (403, 404, 405, 502 or 504).
  """
  @spec forward(
          Config.t(),
          %{String.t() => Upstream.t()},
          String.t(),
          map(),
          %{String.t() => Upstream.t()}
        ) :: {:ok, response()} | {:error, pos_integer(), String.t()}
  def forward(%Config{} = config, upstreams, name, request, declared \\ %{}) do
    with {:ok, upstream} <- allowed(config, upstreams, declared, name),
         :ok <- check_method(upstream, request.method),
         {:ok, path} <- join_path(request.path) do
      url = upstream.base_url <> path
      query = client_query(request.query, upstream)
      cache_key = cache_key(upstream, request.method, url, query)

      if cacheable?(upstream, request.method) do
        cached_call(config, upstream, url, query, request, cache_key)
      else
        call(config, upstream, url, query, request)
      end
    end
  end

  # Host upstreams by name; manifest upstreams by target, so manifests
  # declaring the same provider share entries (ADR 20).
  defp cache_key(%Upstream{origin: :manifest}, method, url, query),
    do: {:manifest, method, url, query}

  defp cache_key(upstream, method, url, query), do: {upstream.name, method, url, query}

  defp allowed(config, upstreams, declared, name) do
    cond do
      Map.has_key?(declared, name) -> {:ok, Map.fetch!(declared, name)}
      name not in config.upstreams -> {:error, 403, "upstream not allowed for this configuration"}
      not Map.has_key?(upstreams, name) -> {:error, 404, "unknown upstream"}
      true -> {:ok, Map.fetch!(upstreams, name)}
    end
  end

  defp check_method(upstream, method) do
    if method in upstream.methods, do: :ok, else: {:error, 405, "method not allowed"}
  end

  # Segments arrive decoded; anything that could change the target path is
  # refused, the rest is encoded again.
  defp join_path(segments) do
    if Enum.all?(segments, &safe_segment?/1) do
      {:ok, Enum.map_join(segments, fn segment -> "/" <> encode(segment) end)}
    else
      {:error, 404, "invalid path"}
    end
  end

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp safe_segment?(segment),
    do: segment not in ["", ".", ".."] and not String.contains?(segment, ["/", "\\", <<0>>])

  defp client_query(query, %Upstream{query: secret_param}) do
    query
    |> URI.query_decoder()
    |> Enum.reject(fn {key, _value} -> key == secret_param end)
  end

  defp cacheable?(%Upstream{cache_ttl: ttl}, "GET"), do: is_integer(ttl)
  defp cacheable?(_upstream, _method), do: false

  # Waiting for a running fetch is bound by what the fetch itself may take.
  defp cached_call(config, upstream, url, query, request, cache_key) do
    wait = @connect_timeout + upstream.timeout + 1_000

    group = stats_group(upstream)

    ttls = %{
      ttl: upstream.cache_ttl,
      stale_ttl: upstream.stale_ttl,
      refresh: upstream.refresh,
      group: group,
      max_size: upstream.cache_size
    }

    fetch = fn ->
      case call(config, upstream, url, query, request) do
        {:ok, %{status: 200} = response} = result ->
          type = content_type(response)

          if Upstream.accepts?(upstream, type) do
            {:cache, result}
          else
            expected = Enum.join(upstream.accepted_types, ", ")
            Stats.failed(group, "answered 200 #{type || "without type"}, expected #{expected}")
            {:failed, result}
          end

        {:ok, %{status: status}} = result when status == 429 or status >= 500 ->
          Stats.failed(group, "answered #{status}")
          {:failed, result}

        {:ok, _response} = result ->
          {:no_cache, result}

        {:error, _status, _message} = error ->
          {:failed, error}
      end
    end

    result = Cache.fetch(cache_key, ttls, wait, fetch)
    if kind = count_as(result), do: Stats.count(group, kind)

    case result do
      {:hit, {:ok, response}, age} -> {:ok, with_cache_headers(response, "hit", age)}
      {:stale, {:ok, response}, age} -> {:ok, with_cache_headers(response, "stale", age)}
      {:miss, {:ok, response}} -> {:ok, with_cache_headers(response, "miss", 0)}
      {:miss, error} -> error
      {:error, :timeout} -> {:error, 504, "upstream #{upstream.name}: timed out"}
      {:error, :crashed} -> failure(config, upstream, 502, "request failed")
    end
  end

  defp content_type(response) do
    Enum.find_value(response.headers, fn {name, value} -> if name == "content-type", do: value end)
  end

  defp count_as({:hit, _value, _age}), do: :hit
  defp count_as({:stale, _value, _age}), do: :stale
  defp count_as({:miss, _value}), do: :miss
  defp count_as(_error), do: nil

  @doc """
  The group an upstream's statistics and cache entries are kept under (see
  `Deepsplay.UpstreamProxy.Stats`).
  """
  @spec stats_group(Upstream.t()) :: Stats.group()
  def stats_group(%Upstream{origin: :manifest, base_url: url}), do: {:manifest, url}
  def stats_group(%Upstream{origin: :backend, name: name}), do: {:backend, name}
  def stats_group(%Upstream{name: name}), do: {:host, name}

  defp with_cache_headers(response, state, age_ms) do
    headers = [{"x-deepsplay-cache", state}, {"age", Integer.to_string(div(age_ms, 1000))}]
    %{response | headers: response.headers ++ headers}
  end

  defp call(config, upstream, url, query, request) do
    with {:ok, headers, query} <- add_secret(upstream, request_headers(request.headers), query),
         {:ok, url, connect} <- target(upstream, url) do
      options =
        [
          method: request.method,
          url: url,
          params: query,
          headers: headers,
          body: request.body,
          receive_timeout: upstream.timeout,
          connect_options: [timeout: @connect_timeout] ++ connect,
          retry: false,
          redirect: false,
          decode_body: false,
          compressed: false,
          into: &limit_body/2
        ] ++ test_options(upstream)

      result = Req.request(options)
      Stats.fetched(stats_group(upstream))

      case result do
        {:ok, %Req.Response{private: %{too_large: true}}} ->
          failure(config, upstream, 502, "response larger than #{div(@max_body, 1024 * 1024)} MB")

        {:ok, %Req.Response{} = response} ->
          {:ok,
           %{status: response.status, headers: response_headers(response), body: response.body}}

        {:error, %Req.TransportError{reason: :timeout}} ->
          failure(config, upstream, 504, "timed out")

        {:error, exception} ->
          failure(config, upstream, 502, Exception.message(exception))
      end
    else
      {:error, message} -> failure(config, upstream, 502, message)
    end
  end

  # Tests send upstream calls to a stub; backends are always real local
  # processes.
  defp test_options(%Upstream{origin: :backend}), do: []
  defp test_options(_upstream), do: Application.get_env(:deepsplay, :proxy_req_options, [])

  # Manifest upstreams connect to a checked public address, with the host
  # name for TLS verification, SNI and the Host header (ADR 19).
  defp target(%Upstream{origin: :manifest}, url) do
    uri = URI.parse(url)

    case Address.resolve(uri.host) do
      {:ok, ip} -> {:ok, URI.to_string(%{uri | host: Address.to_host(ip)}), [hostname: uri.host]}
      {:error, message} -> {:error, message}
    end
  end

  defp target(_upstream, url), do: {:ok, url, []}

  defp request_headers(headers) do
    for {key, value} <- headers, String.downcase(key) in @request_headers, do: {key, value}
  end

  defp add_secret(upstream, headers, query) do
    with {:ok, headers} <- secret_header(upstream, headers),
         {:ok, query} <- secret_query(upstream, query) do
      {:ok, headers, query}
    end
  end

  defp secret_header(%Upstream{header: nil}, headers), do: {:ok, headers}

  defp secret_header(%Upstream{header: header, value: template}, headers) do
    with {:ok, value} <- Secrets.expand(template), do: {:ok, [{header, value} | headers]}
  end

  defp secret_query(%Upstream{query: nil}, query), do: {:ok, query}

  defp secret_query(%Upstream{query: param, query_value: template}, query) do
    with {:ok, value} <- Secrets.expand(template), do: {:ok, query ++ [{param, value}]}
  end

  defp limit_body({:data, data}, {request, response}) do
    body = response.body <> data

    if byte_size(body) > @max_body do
      {:halt,
       {request, %{response | body: "", private: Map.put(response.private, :too_large, true)}}}
    else
      {:cont, {request, %{response | body: body}}}
    end
  end

  defp response_headers(response) do
    for {key, values} <- response.headers,
        key in @response_headers,
        value <- values,
        do: {key, value}
  end

  defp failure(config, upstream, status, message) do
    Stats.failed(stats_group(upstream), message)
    text = "proxy #{upstream.name}: #{message}"
    Logger.warning(~s(config "#{config.name}": #{text}))
    Status.log_error(config.name, text)
    {:error, status, "upstream #{upstream.name}: #{message}"}
  end
end
