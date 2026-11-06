defmodule DeepsplayWeb.RevisionController do
  @moduledoc """
  Serves files of a revision at `/c/<name>/r/<sha>/<path>` (ADR 10).

  Only files in `pages/` below the configuration's root are served; paths are
  relative to it. Hidden files are not served. Files of a revision never
  change, so they are served with a long cache lifetime.

  A local directory (ADR 12) is served live and never cached; its version
  token in the URL changes with every change instead.
  """

  use DeepsplayWeb, :controller

  alias Deepsplay.HostConfig.Config
  alias Deepsplay.HostConfig.Store
  alias Deepsplay.RevisionFile
  alias Deepsplay.RevisionStore
  alias Deepsplay.Screen

  @cache_control "public, max-age=31536000, immutable"

  def show(conn, %{"name" => name, "sha" => sha, "path" => segments}) do
    with {:ok, config} <- Store.lookup(name),
         true <- RevisionFile.sha?(sha),
         {:ok, dir, cache_control} <- content_dir(config, sha),
         {:ok, file} <- RevisionFile.resolve(pages_dir(dir, config), segments) do
      conn
      |> put_resp_header("cache-control", cache_control)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(MIME.from_path(file), nil)
      |> send_file(200, file)
    else
      _not_found -> not_found(conn)
    end
  end

  defp content_dir(%Config{path: path}, _token) when is_binary(path), do: {:ok, path, "no-store"}

  defp content_dir(config, sha) do
    with {:ok, rev_dir} <- RevisionStore.revision_dir(config.repo, sha),
         true <- File.dir?(rev_dir) do
      {:ok, rev_dir, @cache_control}
    end
  end

  defp pages_dir(rev_dir, config), do: rev_dir |> Screen.root(config) |> Screen.pages_dir()

  defp not_found(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found")
  end
end
