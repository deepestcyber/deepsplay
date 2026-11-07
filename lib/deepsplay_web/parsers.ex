defmodule DeepsplayWeb.Parsers do
  @moduledoc """
  `Plug.Parsers`, except for the upstream proxy (`/c/<name>/api/...`), whose
  request bodies must reach the upstream unparsed (ADR 8), backends (ADR 26)
  for the same reason, and shared state
  (`/c/<name>/state/...`), which reads bodies itself within its size limit
  (ADR 21).
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: ["c", _name, "api" | _rest]} = conn, _opts), do: conn
  def call(%Plug.Conn{path_info: ["c", _name, "state" | _rest]} = conn, _opts), do: conn
  def call(%Plug.Conn{path_info: ["c", _name, "backend" | _rest]} = conn, _opts), do: conn
  def call(conn, opts), do: Plug.Parsers.call(conn, opts)
end
