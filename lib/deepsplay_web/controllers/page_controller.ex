defmodule DeepsplayWeb.PageController do
  use DeepsplayWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
