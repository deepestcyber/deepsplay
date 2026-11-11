defmodule DeepsplayWeb.InterruptControllerTest do
  # Not async: uses the global host configuration and secrets.
  use DeepsplayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Deepsplay.ScreenFixture

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.InterruptTokens
  alias Deepsplay.Revisions
  alias Deepsplay.Secrets

  @moduletag :tmp_dir

  @bell """
  <script type="application/toml" id="deepsplay-page">
  [params.who]
  type = "string"

  [params.level]
  type = "int"
  max  = 3

  [params.duration]
  type = "duration"
  from = "duration"
  </script>
  """

  @files %{
    "screen.toml" => """
    [params]
    who = "manifest"

    [[page]]
    path = "a.html"

    [[interrupt]]
    name     = "doorbell"
    path     = "bell.html?level=1"
    duration = "30s"
    priority = 20

    [[interrupt]]
    name     = "plain"
    path     = "a.html"
    duration = "5s"

    [[interrupt]]
    name     = "off"
    path     = "a.html"
    duration = "5s"
    enabled  = false
    """,
    "pages/a.html" => "a",
    "pages/bell.html" => @bell
  }

  setup %{tmp_dir: tmp_dir} do
    %{config: config, sha: sha} = setup_screen(tmp_dir, @files)
    {:ok, ^sha} = Revisions.refresh(config)
    DeepsplayWeb.Interrupts.clear()

    token = InterruptTokens.generate()
    :ok = InterruptTokens.register("lobby", token)
    on_exit(fn -> InterruptTokens.unregister("lobby") end)

    %{sha: sha, token: token}
  end

  defp trigger(method, path, token) do
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
    dispatch(conn, @endpoint, method, path, nil)
  end

  test "starts an interrupt on connected screens", %{conn: conn, sha: sha, token: token} do
    {:ok, view, _html} = live(conn, ~p"/c/lobby")
    {:ok, pinned, _html} = live(build_conn(), ~p"/c/lobby?page=a.html")

    conn = trigger(:post, "/c/lobby/interrupts/doorbell?who=api", token)
    assert json_response(conn, 202) == %{"screens" => 1, "duration" => 30_000}
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    # Trigger parameters first, then the manifest query, then ADR 16 levels.
    url = "/c/lobby/r/#{sha}/bell.html?level=1&who=api&duration=30s"

    assert_push_event(view, "interrupt", %{
      name: "doorbell",
      url: ^url,
      priority: 20,
      duration: 30_000
    })

    # Pinned screens ignore interrupts.
    refute_push_event(pinned, "interrupt", %{})

    conn = trigger(:delete, "/c/lobby/interrupts/doorbell", token)
    assert json_response(conn, 202) == %{"screens" => 1, "duration" => 30_000}
    assert_push_event(view, "interrupt_end", %{name: "doorbell"})
  end

  test "trigger parameters replace those of the manifest path", %{
    conn: conn,
    sha: sha,
    token: token
  } do
    {:ok, view, _html} = live(conn, ~p"/c/lobby")

    conn = trigger(:post, "/c/lobby/interrupts/doorbell?level=3", token)
    assert json_response(conn, 202)

    url = "/c/lobby/r/#{sha}/bell.html?level=3&duration=30s&who=manifest"
    assert_push_event(view, "interrupt", %{url: ^url})
  end

  test "no screens connected", %{token: token} do
    conn = trigger(:post, "/c/lobby/interrupts/plain", token)
    assert json_response(conn, 202) == %{"screens" => 0, "duration" => 5_000}
  end

  test "needs a valid token", %{token: token} do
    assert build_conn() |> post("/c/lobby/interrupts/doorbell") |> json_response(401)

    conn = trigger(:post, "/c/lobby/interrupts/doorbell", token <> "x")
    assert json_response(conn, 401) == %{"error" => "a valid token is needed"}
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    conn =
      build_conn()
      |> put_req_header("authorization", "Basic " <> token)
      |> post("/c/lobby/interrupts/doorbell")

    assert json_response(conn, 401)
  end

  test "a token of the host secret named by interrupt_token" do
    previous = :persistent_term.get({Secrets, :secrets}, %{})
    on_exit(fn -> Secrets.put(previous) end)
    Secrets.put(Map.put(previous, "lobby_trigger", "host-secret"))

    {:ok, host_config} = Store.get()
    Store.put({:ok, put_in(host_config.configs["lobby"].interrupt_token, "lobby_trigger")})

    assert trigger(:post, "/c/lobby/interrupts/plain", "host-secret") |> json_response(202)
  end

  test "unknown, disabled and unknown configuration", %{token: token} do
    assert trigger(:post, "/c/lobby/interrupts/nope", token) |> json_response(404) ==
             %{"error" => "unknown interrupt"}

    assert trigger(:post, "/c/lobby/interrupts/off", token) |> json_response(404)
    assert trigger(:delete, "/c/lobby/interrupts/off", token) |> json_response(404)

    assert trigger(:post, "/c/nowhere/interrupts/plain", token) |> json_response(404) ==
             %{"error" => "unknown configuration"}
  end

  test "parameters are checked against the page", %{token: token} do
    conn = trigger(:post, "/c/lobby/interrupts/doorbell?level=high&colour=red", token)

    assert json_response(conn, 422) == %{
             "error" => "invalid parameters",
             "reasons" => [
               ~s(level="high" is invalid for bell.html),
               ~s(bell.html declares no parameter "colour")
             ]
           }

    conn = trigger(:post, "/c/lobby/interrupts/doorbell?who=a&who=b", token)
    assert %{"reasons" => [~s("who" is given more than once)]} = json_response(conn, 422)

    long = String.duplicate("x", 2100)
    conn = trigger(:post, "/c/lobby/interrupts/doorbell?who=#{long}", token)
    assert %{"reasons" => ["the query is larger than 2 KB"]} = json_response(conn, 422)

    # An undocumented page takes no parameters.
    conn = trigger(:post, "/c/lobby/interrupts/plain?x=1", token)
    assert %{"reasons" => [~s(a.html declares no parameter "x")]} = json_response(conn, 422)
  end

  test "the same interrupt at most every 2 seconds", %{token: token} do
    assert trigger(:post, "/c/lobby/interrupts/plain", token) |> json_response(202)

    assert trigger(:post, "/c/lobby/interrupts/plain", token) |> json_response(429) ==
             %{"error" => "triggered again within 2 seconds"}

    # Others are not limited, and neither is ending one.
    assert trigger(:post, "/c/lobby/interrupts/doorbell", token) |> json_response(202)
    assert trigger(:delete, "/c/lobby/interrupts/plain", token) |> json_response(202)

    assert %{
             "plain" => %{action: :stop, status: 202, screens: 0},
             "doorbell" => %{action: :start, status: 202}
           } = DeepsplayWeb.Interrupts.last("lobby")
  end
end
