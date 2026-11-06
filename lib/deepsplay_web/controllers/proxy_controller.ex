defmodule DeepsplayWeb.ProxyController do
  @moduledoc """
  The upstream proxy at `/c/<name>/api/<upstream>/<path>` (ADR 8, ADR 10).
  See `Deepsplay.UpstreamProxy`.
  """

  use DeepsplayWeb, :controller

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.UpstreamProxy

  @max_request_body 1024 * 1024

  def forward(conn, %{"name" => name, "upstream" => upstream, "path" => path}) do
    with {:ok, config} <- lookup(name),
         {:ok, upstreams} <- upstreams(),
         {:ok, body, conn} <- read_request_body(conn),
         request = %{
           method: conn.method,
           path: path,
           query: conn.query_string,
           headers: conn.req_headers,
           body: body
         },
         {:ok, response} <- UpstreamProxy.forward(config, upstreams, upstream, request) do
      conn
      |> merge_resp_headers(response.headers)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(response.status, response.body)
    else
      {:error, status, message} -> error(conn, status, message)
    end
  end

  defp lookup(name) do
    case Store.lookup(name) do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> {:error, 404, "unknown configuration"}
    end
  end

  defp upstreams do
    case Store.get() do
      {:ok, host_config} -> {:ok, host_config.upstreams}
      {:error, _errors} -> {:error, 503, "host configuration unusable"}
    end
  end

  defp read_request_body(conn) do
    case read_body(conn, length: @max_request_body) do
      {:ok, "", conn} -> {:ok, nil, conn}
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, 413, "request body too large"}
      {:error, _reason} -> {:error, 400, "cannot read request body"}
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end
end
