defmodule DeepsplayWeb.InterruptPagesTest do
  # Not async: uses the global host configuration.
  use DeepsplayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Deepsplay.ScreenFixture

  alias Deepsplay.InterruptTokens
  alias DeepsplayWeb.Presence
  alias Deepsplay.Revisions

  @moduletag :tmp_dir

  @files %{
    "screen.toml" => """
    [[page]]
    path = "a.html"

    [[interrupt]]
    name        = "doorbell"
    path        = "a.html?bell=1"
    duration    = "30s"
    priority    = 20
    description = "Someone at the door"

    [[interrupt]]
    name     = "off"
    path     = "a.html"
    duration = "5s"
    enabled  = false
    """,
    "pages/a.html" => "a"
  }

  setup %{tmp_dir: tmp_dir} do
    %{config: config, sha: sha} = setup_screen(tmp_dir, @files)
    {:ok, ^sha} = Revisions.refresh(config)
    DeepsplayWeb.Interrupts.clear()

    token = InterruptTokens.generate()
    :ok = InterruptTokens.register("lobby", token)
    on_exit(fn -> InterruptTokens.unregister("lobby") end)
    %{token: token}
  end

  # Waits until the screen has joined, as the status page learns of it.
  defp connect_screen do
    Phoenix.PubSub.subscribe(Deepsplay.PubSub, Presence.topic())
    {:ok, screen, _html} = live(build_conn(), ~p"/c/lobby")

    receive do
      %Phoenix.Socket.Broadcast{event: "presence_diff", payload: %{joins: joins}}
      when joins != %{} ->
        :ok
    after
      3_000 -> flunk("the screen did not join")
    end

    screen
  end

  defp trigger(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> post("/c/lobby/interrupts/doorbell")
    |> json_response(202)
  end

  test "the catalog lists interrupts with their trigger and last trigger", %{
    conn: conn,
    token: token
  } do
    {:ok, view, _html} = live(conn, ~p"/catalog/lobby")

    assert has_element?(view, "#interrupt-doorbell", "Someone at the door")
    assert has_element?(view, "#interrupt-doorbell", "a.html?bell=1")
    assert has_element?(view, "#interrupt-doorbell", "up to 30s · priority 20")

    assert has_element?(
             view,
             "#interrupt-doorbell .interrupt-curl",
             "/c/lobby/interrupts/doorbell"
           )

    assert has_element?(view, "#interrupt-doorbell .interrupt-curl", "Bearer $TOKEN")
    assert has_element?(view, "#interrupt-doorbell .interrupt-last", "not triggered")
    refute has_element?(view, "#interrupt-off")
    assert has_element?(view, "#catalog-disabled", "off")
    assert has_element?(view, "#catalog-disabled", "(interrupt)")

    connect_screen()
    trigger(token)
    assert has_element?(view, "#interrupt-doorbell .interrupt-last", "POST")
    assert has_element?(view, "#interrupt-doorbell .interrupt-last", "202 to 1 screen")
  end

  test "the status page shows connected screens and the last triggers", %{
    conn: conn,
    token: token
  } do
    {:ok, view, _html} = live(conn, ~p"/status")
    assert has_element?(view, "#config-lobby .config-screens", "0 screens")
    assert has_element?(view, "#interrupt-lobby-doorbell", "20")
    assert has_element?(view, "#interrupt-lobby-doorbell", "–")

    connect_screen()
    assert has_element?(view, "#config-lobby .config-screens", "1 screen")

    trigger(token)
    assert has_element?(view, "#interrupt-lobby-doorbell", "POST")
    assert has_element?(view, "#interrupt-lobby-doorbell", "202 to 1 screen")
  end
end
