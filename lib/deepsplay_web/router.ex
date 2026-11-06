defmodule DeepsplayWeb.Router do
  use DeepsplayWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DeepsplayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Upstream proxy: no session, no CSRF, any method (ADR 8).
  scope "/c/:name/api/:upstream", DeepsplayWeb do
    match :*, "/*path", ProxyController, :forward
  end

  # Files of a revision: no session, no CSRF, any content type (ADR 10).
  scope "/c/:name/r/:sha", DeepsplayWeb do
    get "/*path", RevisionController, :show
  end

  scope "/", DeepsplayWeb do
    pipe_through :browser

    live "/", ShellLive, :default
    live "/c/:name", ShellLive, :named
    live "/status", StatusLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", DeepsplayWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:deepsplay, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DeepsplayWeb.Telemetry
    end
  end
end
