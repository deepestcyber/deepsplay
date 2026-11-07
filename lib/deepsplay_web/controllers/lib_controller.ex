defmodule DeepsplayWeb.LibController do
  @moduledoc """
  Serves the page helper `deepsplay.js` (ADR 14):

    * `/lib/v1/deepsplay.js`: the current build, compatible within `v1`;
      cached for a day, then up to a week while revalidating in the
      background, so screens keep working when the server is unreachable.
    * `/lib/deepsplay@X.Y.Z.js`: one exact version, cached immutably. The
      current version is the current build; earlier ones come from
      `priv/lib/archive/`, where each release adds its build.
  """

  use DeepsplayWeb, :controller

  @v1_cache "public, max-age=86400, stale-while-revalidate=604800"
  @exact_cache "public, max-age=31536000, immutable"

  def v1(conn, _params), do: serve(conn, current_file(), @v1_cache)

  def exact(conn, %{"file" => file}) do
    current = "deepsplay@#{version()}.js"

    cond do
      file == current ->
        serve(conn, current_file(), @exact_cache)

      Regex.match?(~r/^deepsplay@\d+\.\d+\.\d+\.js$/, file) ->
        serve(conn, archived(file), @exact_cache)

      true ->
        not_found(conn)
    end
  end

  @doc false
  def version, do: Application.spec(:deepsplay, :vsn) |> to_string()

  defp current_file, do: Application.app_dir(:deepsplay, "priv/lib/deepsplay.js")
  defp archived(file), do: Application.app_dir(:deepsplay, Path.join("priv/lib/archive", file))

  defp serve(conn, path, cache_control) do
    if File.regular?(path) do
      conn
      |> put_resp_header("cache-control", cache_control)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type("text/javascript")
      |> send_file(200, path)
    else
      not_found(conn)
    end
  end

  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found")
  end
end
