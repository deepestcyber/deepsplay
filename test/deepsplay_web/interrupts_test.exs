defmodule DeepsplayWeb.InterruptsTest do
  # Not async: uses the global host configuration and the shared trigger table.
  use DeepsplayWeb.ConnCase, async: false

  import Deepsplay.ScreenFixture

  alias Deepsplay.HostConfig.Store
  alias Deepsplay.Revisions
  alias DeepsplayWeb.Interrupts

  @moduletag :tmp_dir

  @files %{
    "screen.toml" => """
    [[page]]
    path = "a.html"

    [[interrupt]]
    name     = "doorbell"
    path     = "bell.html"
    duration = "30s"
    """,
    "pages/a.html" => "a",
    "pages/bell.html" => """
    <script type="application/toml" id="deepsplay-page">
    [params.who]
    type = "string"
    </script>
    """
  }

  setup %{tmp_dir: tmp_dir} do
    %{config: config, sha: sha} = setup_screen(tmp_dir, @files)
    {:ok, ^sha} = Revisions.refresh(config)
    Interrupts.clear()
    {:ok, config} = Store.lookup("lobby")
    %{config: config}
  end

  describe "start/4" do
    test "starts from parameters and records the source", %{config: config} do
      :ok = Interrupts.subscribe("lobby")

      assert {:ok, %{screens: 0, duration: 30_000}} =
               Interrupts.start(config, "doorbell", {:ok, [{"who", "Ada"}]}, :mqtt)

      assert_receive {:interrupt, %{name: "doorbell", url: url}}
      assert url =~ "bell.html?who=Ada"

      assert %{"doorbell" => %{source: :mqtt, action: :start, status: 202, reasons: []}} =
               Interrupts.last("lobby")
    end

    test "the rate limit is shared by HTTP and MQTT", %{config: config} do
      assert {:ok, _} = Interrupts.start(config, "doorbell", {:ok, []}, :http)
      assert {:error, :too_many} = Interrupts.start(config, "doorbell", {:ok, []}, :mqtt)
      assert %{"doorbell" => %{source: :mqtt, status: 429}} = Interrupts.last("lobby")
    end

    test "parameters that could not be read are recorded with their reasons", %{config: config} do
      params = {:error, {:invalid, ["the payload is not JSON"]}}

      assert {:error, {:invalid, ["the payload is not JSON"]}} =
               Interrupts.start(config, "doorbell", params, :mqtt)

      assert %{"doorbell" => %{status: 422, reasons: ["the payload is not JSON"]}} =
               Interrupts.last("lobby")
    end

    test "parameters the page does not declare", %{config: config} do
      assert {:error, {:invalid, [reason]}} =
               Interrupts.start(config, "doorbell", {:ok, [{"what", "x"}]}, :mqtt)

      assert reason =~ "what"
    end

    test "an unknown interrupt is reported before unreadable parameters", %{config: config} do
      params = {:error, {:invalid, ["broken"]}}
      assert {:error, :not_found} = Interrupts.start(config, "nope", params, :mqtt)
      assert Interrupts.last("lobby") == %{}
    end
  end

  describe "parse_query/1" do
    test "reads pairs in order and rejects repeated names and large queries" do
      assert Interrupts.parse_query(nil) == {:ok, []}
      assert Interrupts.parse_query("a=1&b=x%20y") == {:ok, [{"a", "1"}, {"b", "x y"}]}

      assert Interrupts.parse_query("a=1&a=2") ==
               {:error, {:invalid, [~s("a" is given more than once)]}}

      assert {:error, {:invalid, ["the query is larger than 2 KB"]}} =
               Interrupts.parse_query(String.duplicate("a", 2049))
    end
  end

  describe "describe/1" do
    @at ~U[2027-03-04 10:00:00.123Z]

    test "HTTP triggers with method and status" do
      entry = %{at: @at, action: :start, source: :http, status: 202, screens: 1, reasons: []}
      assert Interrupts.describe(entry) == "POST 2027-03-04 10:00:00 UTC, 202 to 1 screen"

      entry = %{entry | action: :stop, screens: 2}
      assert Interrupts.describe(entry) == "DELETE 2027-03-04 10:00:00 UTC, 202 to 2 screens"

      entry = %{entry | action: :start, status: 422, screens: nil}
      assert Interrupts.describe(entry) == "POST 2027-03-04 10:00:00 UTC, 422"
    end

    test "MQTT triggers with a worded outcome" do
      entry = %{at: @at, action: :start, source: :mqtt, status: 202, screens: 2, reasons: []}
      assert Interrupts.describe(entry) == "MQTT 2027-03-04 10:00:00 UTC, started on 2 screens"

      assert Interrupts.describe(%{entry | status: 429, screens: nil}) ==
               "MQTT 2027-03-04 10:00:00 UTC, ignored, started within 2 seconds"

      assert Interrupts.describe(%{entry | status: 422, screens: nil, reasons: ["a", "b"]}) ==
               "MQTT 2027-03-04 10:00:00 UTC, invalid parameters: a; b"
    end
  end
end
