defmodule DeepsplayWeb.BackendController do
  @moduledoc """
  Forwards `/c/<name>/backend/<path>` to the configuration's backend
  (ADR 26), through `Deepsplay.UpstreamProxy`: any method, the same path
  checks, forwarded headers, timeouts and size limits as for upstreams, no
  secrets added.

  Answers `404` if the configuration has no running backend, `503` while it
  is restarting.
  """

  use DeepsplayWeb, :controller

  alias Deepsplay.Backend
  alias Deepsplay.Backends
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.HostConfig.Upstream
  alias Deepsplay.UpstreamProxy

  @max_request_body 1024 * 1024
  @methods ~w(GET HEAD POST PUT PATCH DELETE)
  @timeout 30_000

  def forward(conn, %{"name" => name, "path" => path}) do
    with {:ok, config} <- lookup(name),
         {:ok, port} <- backend_port(config),
         {:ok, body, conn} <- read_request_body(conn),
         upstream = %Upstream{
           name: "backend",
           base_url: "http://127.0.0.1:#{port}",
           methods: @methods,
           timeout: @timeout,
           origin: :backend
         },
         request = %{
           method: conn.method,
           path: path,
           query: conn.query_string,
           headers: conn.req_headers,
           body: body
         },
         {:ok, response} <-
           UpstreamProxy.forward(config, %{}, "backend", request, %{"backend" => upstream}) do
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

  defp backend_port(config) do
    with %{pid: pid} <- Backends.current(config.name),
         %{state: state, port: port} <- safe_info(pid) do
      if state == :ready, do: {:ok, port}, else: {:error, 503, "backend is #{state}"}
    else
      _none -> {:error, 404, "no backend is running for this configuration"}
    end
  end

  defp safe_info(pid) do
    Backend.info(pid)
  catch
    :exit, _gone -> nil
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
