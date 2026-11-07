defmodule DeepsplayWeb.StateController do
  @moduledoc """
  Shared state for pages at `/c/<name>/state/` (ADR 21). See `Deepsplay.State`.

    * `GET /c/<name>/state/<key>` - the JSON value, with `ETag: "<version>"`
    * `PUT /c/<name>/state/<key>` - stores the JSON body; `If-Match` and
      `If-None-Match: *` make it conditional
    * `DELETE /c/<name>/state/<key>` - deletes; `If-Match` as for `PUT`
    * `POST /c/<name>/state/<key>` with `{"increment": n}` - adds to a number
    * `GET /c/<name>/state/?prefix=<prefix>` - keys with their versions

  Errors answer `{"error": "..."}`. Answers are never cached.
  """

  use DeepsplayWeb, :controller

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.State

  @max_body 64 * 1024 + 1

  def show(conn, %{"key" => key}) do
    with {:ok, namespace} <- namespace(conn),
         {:ok, key} <- key(key) do
      case State.get(namespace, key) do
        {:ok, json, version} ->
          conn |> etag(version) |> json_resp(200, json)

        :error ->
          error(conn, 404, "no value")
      end
    end
    |> respond(conn)
  end

  def list(conn, params) do
    with {:ok, namespace} <- namespace(conn) do
      keys =
        for {key, version} <- State.list(namespace, params["prefix"] || ""),
            do: %{key: key, version: version}

      json_resp(conn, 200, Jason.encode!(%{keys: keys}))
    end
    |> respond(conn)
  end

  def put(conn, %{"key" => key}) do
    with {:ok, namespace} <- namespace(conn),
         {:ok, key} <- key(key),
         {:ok, conditions} <- conditions(conn),
         {:ok, json, conn} <- body(conn),
         {:ok, version} <- State.put(namespace, key, json, conditions) do
      conn |> etag(version) |> json_resp(200, Jason.encode!(%{version: version}))
    end
    |> respond(conn)
  end

  def delete(conn, %{"key" => key}) do
    with {:ok, namespace} <- namespace(conn),
         {:ok, key} <- key(key),
         {:ok, conditions} <- conditions(conn),
         :ok <- State.delete(namespace, key, Keyword.take(conditions, [:if_match])) do
      conn |> no_store() |> send_resp(204, "")
    end
    |> respond(conn)
  end

  def increment(conn, %{"key" => key}) do
    with {:ok, namespace} <- namespace(conn),
         {:ok, key} <- key(key),
         {:ok, json, conn} <- body(conn),
         {:ok, by} <- increment_by(json),
         {:ok, value, version} <- State.increment(namespace, key, by) do
      conn |> etag(version) |> json_resp(200, Jason.encode!(%{value: value, version: version}))
    end
    |> respond(conn)
  end

  # Turns errors of the steps into answers; a finished conn passes through.
  defp respond(%Plug.Conn{} = done, _conn), do: done
  defp respond({:error, status, message}, conn), do: error(conn, status, message)
  defp respond({:error, reason}, conn) when is_atom(reason), do: state_error(conn, reason)

  defp namespace(conn) do
    with {:ok, host_config} <- host_config(),
         {:ok, config} <- lookup(conn.path_params["name"]) do
      case State.namespace(host_config, config) do
        nil -> {:error, 404, "no shared state for this configuration"}
        namespace -> {:ok, namespace}
      end
    end
  end

  defp host_config do
    case Store.get() do
      {:ok, host_config} -> {:ok, host_config}
      {:error, _errors} -> {:error, 503, "host configuration unusable"}
    end
  end

  defp lookup(name) do
    case Store.lookup(name) do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> {:error, 404, "unknown configuration"}
    end
  end

  defp key(segments) do
    key = Enum.join(segments, "/")
    if State.valid_key?(key), do: {:ok, key}, else: {:error, 400, "invalid key"}
  end

  defp conditions(conn) do
    case {get_req_header(conn, "if-match"), get_req_header(conn, "if-none-match")} do
      {[], []} ->
        {:ok, []}

      {[], ["*"]} ->
        {:ok, [if_none_match: true]}

      {[tag], []} ->
        case Integer.parse(String.trim(tag, ~s("))) do
          {version, ""} -> {:ok, [if_match: version]}
          _other -> {:error, 400, "If-Match must be a version"}
        end

      _other ->
        {:error, 400, ~s(only one If-Match: "<version>" or If-None-Match: * is supported)}
    end
  end

  # Bodies arrive unparsed (`DeepsplayWeb.Parsers`), whatever their type.
  defp body(conn) do
    case read_body(conn, length: @max_body) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _reason} -> {:error, 400, "cannot read request body"}
    end
  end

  defp increment_by(json) do
    case Jason.decode(json) do
      {:ok, %{"increment" => by}} when is_number(by) -> {:ok, by}
      _other -> {:error, 400, ~s(body must be {"increment": <number>})}
    end
  end

  defp etag(conn, version), do: put_resp_header(conn, "etag", ~s("#{version}"))

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  defp json_resp(conn, status, json) do
    conn
    |> no_store()
    |> put_resp_content_type("application/json")
    |> send_resp(status, json)
  end

  defp state_error(conn, :invalid_key), do: error(conn, 400, "invalid key")
  defp state_error(conn, :invalid_json), do: error(conn, 400, "body must be JSON")
  defp state_error(conn, :precondition), do: error(conn, 412, "version does not match")
  defp state_error(conn, :too_large), do: error(conn, 413, "value larger than 64 KB")
  defp state_error(conn, :full), do: error(conn, 507, "namespace full")
  defp state_error(conn, :not_a_number), do: error(conn, 409, "value is not a number")

  defp error(conn, status, message),
    do: json_resp(conn, status, Jason.encode!(%{error: message}))
end
