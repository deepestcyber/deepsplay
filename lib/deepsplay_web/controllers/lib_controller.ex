defmodule DeepsplayWeb.LibController do
  @moduledoc """
  Serves the page helper `deepsplay.js` (ADR 14):

    * `/lib/v1/deepsplay.js`: the current build, compatible within `v1`;
      fresh for an hour, then used for up to 30 days while revalidating in
      the background, so a new build reaches screens soon and screens keep
      working when the server is unreachable. An `ETag` (hash of the file)
      makes the revalidation a `304` while the build is unchanged.
    * `/lib/deepsplay@X.Y.Z.js`: one exact version, cached immutably. The
      current version is the current build; earlier ones come from
      `priv/lib/archive/`, where each release adds its build.
  """

  use DeepsplayWeb, :controller

  @v1_cache "public, max-age=3600, stale-while-revalidate=2592000"
  @exact_cache "public, max-age=31536000, immutable"

  def v1(conn, _params) do
    path = current_file()

    case etag(path) do
      nil ->
        not_found(conn)

      etag ->
        conn = put_resp_header(conn, "etag", etag)

        if etag in if_none_match(conn) do
          conn
          |> put_resp_header("cache-control", @v1_cache)
          |> send_resp(304, "")
        else
          serve(conn, path, @v1_cache)
        end
    end
  end

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

  # A strong ETag from the file's content. The file is small and screens ask
  # for it at most hourly, so it is hashed on each request.
  defp etag(path) do
    case File.read(path) do
      {:ok, content} ->
        hash = :crypto.hash(:sha256, content) |> Base.url_encode64(padding: false)
        ~s("#{binary_part(hash, 0, 22)}")

      {:error, _} ->
        nil
    end
  end

  defp if_none_match(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
  end

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
