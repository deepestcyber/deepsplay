defmodule DeepsplayWeb.ShellLiveTest do
  # Not async: some tests replace the globally stored host configuration.
  use DeepsplayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Deepsplay.HostConfig.Store

  # The fixture loaded at start: test/support/fixtures/host.toml

  describe "with a valid host configuration" do
    test "/ shows the default configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#fallback-no-revision")
      assert has_element?(view, "#fallback-config", "lobby")
      assert has_element?(view, "#fallback-ref", "main")
    end

    test "never shows credentials from the repository URL", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#fallback-repo", "https://***@example.com/lobby-screen.git")
      refute html =~ "secret-token"
    end

    test "/c/:name shows the named configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/c/kitchen")

      assert has_element?(view, "#fallback-config", "kitchen")
      assert has_element?(view, "#fallback-repo", "git@example.com:example/private-screens.git")
    end

    test "an unknown name shows the fallback page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/c/nowhere")

      assert has_element?(view, "#fallback-unknown-config", "nowhere")
    end
  end

  describe "with an unusable host configuration" do
    setup do
      previous = Store.get()
      Store.put({:error, ["server.cache_dir is missing", "config #1.ref is missing"]})
      on_exit(fn -> Store.put(previous) end)
    end

    test "every screen shows the errors", %{conn: conn} do
      for path <- [~p"/", ~p"/c/lobby", ~p"/c/nowhere"] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "#fallback-host-config")
        assert has_element?(view, "#fallback-errors li", "server.cache_dir is missing")
        assert has_element?(view, "#fallback-errors li", "config #1.ref is missing")
      end
    end
  end
end
