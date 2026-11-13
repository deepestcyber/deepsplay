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

    test "screens are in kiosk mode by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#screen.cursor-none")
      refute has_element?(view, "#dev-overlay")
    end
  end

  describe "when the host configuration changes" do
    setup do
      previous = Store.get()
      on_exit(fn -> Store.put(previous) end)
      {:ok, host_config} = previous
      %{host_config: host_config}
    end

    defp change(fun) do
      {:ok, host_config} = Store.get()
      Store.put({:ok, fun.(host_config)})

      Phoenix.PubSub.broadcast(
        Deepsplay.PubSub,
        Deepsplay.HostConfig.Watcher.topic(),
        {:host_config_changed}
      )
    end

    test "reloads a screen whose configuration changed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/c/kitchen?screen=hall")

      change(&update_in(&1.configs["kitchen"], fn config -> %{config | description: "new"} end))
      assert_redirect(view, "/c/kitchen?screen=hall")
    end

    test "keeps a screen whose configuration did not change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/c/kitchen")

      change(&update_in(&1.configs["lobby"], fn config -> %{config | description: "new"} end))
      assert has_element?(view, "#fallback-config", "kitchen")
      refute_redirected(view, "/c/kitchen")
    end

    test "kiosk mode switched off shows the pointer, without a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/c/kitchen")
      assert has_element?(view, "#screen.cursor-none")

      change(&%{&1 | kiosk_mode: false})
      refute has_element?(view, "#screen.cursor-none")
      assert has_element?(view, "#fallback-config", "kitchen")
      refute_redirected(view, "/c/kitchen")
    end

    test "the development overlay appears without a reload, with its links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/c/kitchen")
      refute has_element?(view, "#dev-overlay")

      change(&%{&1 | dev_overlay: true})
      assert has_element?(view, "#dev-overlay #dev-overlay-clock")
      assert has_element?(view, "#dev-overlay #dev-overlay-skip")
      assert has_element?(view, ~s(#dev-overlay-catalog[href="/catalog/kitchen"]))
      assert has_element?(view, ~s(#dev-overlay-status[href="/status"]))
      refute_redirected(view, "/c/kitchen")
    end

    test "the development overlay of an unknown configuration links to the status only", %{
      conn: conn
    } do
      change(&%{&1 | dev_overlay: true})
      {:ok, view, _html} = live(conn, ~p"/c/nowhere")

      assert has_element?(view, "#dev-overlay-status")
      refute has_element?(view, "#dev-overlay-catalog")
    end

    test "reloads a screen of a configuration that appears", %{
      conn: conn,
      host_config: host_config
    } do
      {:ok, view, _html} = live(conn, ~p"/c/hall")
      assert has_element?(view, "#fallback-unknown-config")

      change(&put_in(&1.configs["hall"], %{host_config.configs["kitchen"] | name: "hall"}))
      assert_redirect(view, "/c/hall")
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
