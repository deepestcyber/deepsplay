defmodule DeepsplayWeb.InterruptController do
  @moduledoc """
  Triggers interrupts (ADR 32):

    * `POST /c/<name>/interrupts/<interrupt>?<params>` starts it on the
      screens of the configuration connected now
    * `DELETE /c/<name>/interrupts/<interrupt>` ends it on the screens
      showing it

  Both need `Authorization: Bearer <token>`: a backend's `DEEPSPLAY_TOKEN`,
  or the host secret named by the configuration's `interrupt_token`.

  Answers: `202` with `{"screens": n, "duration": ms}`; `401` without a
  valid token; `404` for an unknown configuration, a configuration without a
  revision, or an unknown or disabled interrupt; `422` with `reasons` for
  parameters that do not fit; `429` when the same interrupt was started
  within 2 seconds. Errors answer `{"error": "..."}`. Answers are never
  cached.
  """

  use DeepsplayWeb, :controller

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.InterruptTokens
  alias DeepsplayWeb.Interrupts

  def start(conn, %{"interrupt" => name}) do
    with {:ok, config} <- authorize(conn) do
      params = Interrupts.parse_query(conn.query_string)
      conn |> answer(Interrupts.start(config, name, params, :http))
    end
  end

  def stop(conn, %{"interrupt" => name}) do
    with {:ok, config} <- authorize(conn) do
      conn |> answer(Interrupts.stop(config, name))
    end
  end

  # The configuration first: tokens belong to one.
  defp authorize(conn) do
    case Store.lookup(conn.path_params["name"]) do
      {:ok, config} ->
        if InterruptTokens.valid?(config, bearer(conn)),
          do: {:ok, config},
          else:
            conn
            |> put_resp_header("www-authenticate", "Bearer")
            |> error(401, "a valid token is needed")

      {:error, _unknown_or_broken} ->
        error(conn, 404, "unknown configuration")
    end
  end

  defp bearer(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      String.trim(token)
    else
      _missing -> nil
    end
  end

  defp answer(conn, {:ok, %{screens: screens, duration: duration}}),
    do: json_resp(conn, 202, %{screens: screens, duration: duration})

  defp answer(conn, {:error, :not_found}), do: error(conn, 404, "unknown interrupt")

  defp answer(conn, {:error, :too_many}),
    do: error(conn, 429, "triggered again within 2 seconds")

  defp answer(conn, {:error, {:invalid, reasons}}),
    do: json_resp(conn, 422, %{error: "invalid parameters", reasons: reasons})

  defp error(conn, status, message), do: json_resp(conn, status, %{error: message})

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
