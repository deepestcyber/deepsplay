defmodule DeepsplayWeb.Parsers do
  @moduledoc """
  `Plug.Parsers`, except for the upstream proxy (`/c/<name>/api/...`), whose
  request bodies must reach the upstream unparsed (ADR 8).
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: ["c", _name, "api" | _rest]} = conn, _opts), do: conn
  def call(conn, opts), do: Plug.Parsers.call(conn, opts)
end
