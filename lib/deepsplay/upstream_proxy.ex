defmodule Deepsplay.UpstreamProxy do
  @moduledoc """
  Forwards page requests to host-defined upstreams, adding secrets on the
  server (ADR 8).

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
    upstream call,
  - returns only the status, the body and safe response headers.

  Secret values never appear in logs, errors or responses.
  """

  require Logger

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Upstream
  alias Deepsplay.Secrets
  alias Deepsplay.Status
  alias Deepsplay.UpstreamProxy.Cache

  @max_body 5 * 1024 * 1024
  @connect_timeout 5_000
  @request_headers ~w(accept accept-language content-type)
  @response_headers ~w(content-type cache-control etag last-modified expires)

  @type response :: %{status: pos_integer(), headers: [{String.t(), String.t()}], body: binary()}

  @doc """
  Forwards a request. `upstreams` is the host configuration's upstream map.

  Returns the upstream's response, or `{:error, status, message}` with the
  status to answer the page with (403, 404, 405, 502 or 504).
  """
  @spec forward(Config.t(), %{String.t() => Upstream.t()}, String.t(), map()) ::
          {:ok, response()} | {:error, pos_integer(), String.t()}
  def forward(%Config{} = config, upstreams, name, request) do
    with {:ok, upstream} <- allowed(config, upstreams, name),
         :ok <- check_method(upstream, request.method),
         {:ok, path} <- join_path(request.path) do
      url = upstream.base_url <> path
      query = client_query(request.query, upstream)
      cache_key = {upstream.name, request.method, url, query}

      case cached(upstream, request.method, cache_key) do
        {:ok, response} -> {:ok, response}
        :miss -> call(config, upstream, url, query, request, cache_key)
      end
    end
  end

  defp allowed(config, upstreams, name) do
    cond do
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

  defp cached(%Upstream{cache_ttl: ttl}, "GET", key) when is_integer(ttl), do: Cache.get(key)
  defp cached(_upstream, _method, _key), do: :miss

  defp call(config, upstream, url, query, request, cache_key) do
    with {:ok, headers, query} <- add_secret(upstream, request_headers(request.headers), query) do
      options =
        [
          method: request.method,
          url: url,
          params: query,
          headers: headers,
          body: request.body,
          receive_timeout: upstream.timeout,
          connect_options: [timeout: @connect_timeout],
          retry: false,
          redirect: false,
          decode_body: false,
          compressed: false,
          into: &limit_body/2
        ] ++ Application.get_env(:deepsplay, :proxy_req_options, [])

      case Req.request(options) do
        {:ok, %Req.Response{private: %{too_large: true}}} ->
          failure(config, upstream, 502, "response larger than #{div(@max_body, 1024 * 1024)} MB")

        {:ok, %Req.Response{} = response} ->
          result = %{
            status: response.status,
            headers: response_headers(response),
            body: response.body
          }

          if request.method == "GET" and response.status == 200 and upstream.cache_ttl,
            do: Cache.put(cache_key, result, upstream.cache_ttl)

          {:ok, result}

        {:error, %Req.TransportError{reason: :timeout}} ->
          failure(config, upstream, 504, "timed out")

        {:error, exception} ->
          failure(config, upstream, 502, Exception.message(exception))
      end
    else
      {:error, message} -> failure(config, upstream, 502, message)
    end
  end

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
    text = "proxy #{upstream.name}: #{message}"
    Logger.warning(~s(config "#{config.name}": #{text}))
    Status.log_error(config.name, text)
    {:error, status, "upstream #{upstream.name}: #{message}"}
  end
end
