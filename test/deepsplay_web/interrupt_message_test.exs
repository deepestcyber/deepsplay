defmodule DeepsplayWeb.InterruptMessageTest do
  # Not async: uses the global host configuration and the shared trigger table.
  use DeepsplayWeb.ConnCase, async: false

  import Deepsplay.ScreenFixture
  import ExUnit.CaptureLog

  alias Deepsplay.Revisions
  alias DeepsplayWeb.InterruptMessage
  alias DeepsplayWeb.Interrupts

  doctest InterruptMessage

  describe "match/2" do
    test "names and + levels, the same number of levels" do
      assert InterruptMessage.match("a/+", "a/bell") == {:ok, "bell"}
      assert InterruptMessage.match("+/x/+", "lobby/x/bell") == {:ok, "bell"}
      assert InterruptMessage.match("a/+", "a/b/bell") == :nomatch
      assert InterruptMessage.match("a/b/+", "a/bell") == :nomatch
      assert InterruptMessage.match("a/+", "b/bell") == :nomatch
      assert InterruptMessage.match("a/+", "A/bell") == :nomatch
    end

    test "topics starting with $ never match" do
      assert InterruptMessage.match("+/+", "$SYS/bell") == :nomatch
    end
  end

  describe "params/1" do
    test "strings, numbers, booleans and null" do
      assert InterruptMessage.params(~s({"a": "x", "b": 5, "c": 2.5, "d": false, "e": null})) ==
               {:ok, [{"a", "x"}, {"b", "5"}, {"c", "2.5"}, {"d", "false"}]}

      assert InterruptMessage.params("{}") == {:ok, []}
    end

    test "rejects nested values, non-objects, invalid JSON and large payloads" do
      assert InterruptMessage.params(~s({"a": [1], "b": {"c": 1}, "d": "ok"})) ==
               {:error,
                {:invalid,
                 [
                   ~s("a" must be a string, number or boolean),
                   ~s("b" must be a string, number or boolean)
                 ]}}

      assert InterruptMessage.params(~s(["a"])) ==
               {:error, {:invalid, ["the payload is not a JSON object"]}}

      assert InterruptMessage.params(~s("a")) ==
               {:error, {:invalid, ["the payload is not a JSON object"]}}

      assert InterruptMessage.params("{") == {:error, {:invalid, ["the payload is not JSON"]}}

      large = ~s({"who": "#{String.duplicate("a", 2048)}"})

      assert InterruptMessage.params(large) ==
               {:error, {:invalid, ["the payload is larger than 2 KB"]}}
    end
  end

  describe "dispatch/3" do
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
      extra = """
      mqtt_topic = "deepcyber/lobby/interrupts/+"

      [[config]]
      name       = "hall"
      path       = "#{tmp_dir}/hall"
      mqtt_topic = "deepcyber/+/interrupts/+"

      [[config]]
      name = "quiet"
      path = "#{tmp_dir}/quiet"

      [mqtt]
      url = "mqtt://localhost"
      """

      %{config: config, sha: sha} = setup_screen(tmp_dir, @files, extra)
      {:ok, ^sha} = Revisions.refresh(config)
      Interrupts.clear()
      :ok
    end

    test "triggers the interrupt in every configuration whose filter matches" do
      :ok = Interrupts.subscribe("lobby")

      log =
        capture_log(fn ->
          # "hall" matches too, but has no revision: not found there.
          assert [
                   {"hall", {:error, :not_found}},
                   {"lobby", {:ok, %{screens: 0, duration: 30_000}}}
                 ] =
                   InterruptMessage.dispatch(
                     "deepcyber/lobby/interrupts/doorbell",
                     ~s({"who": "Ada"}),
                     false
                   )
        end)

      assert_receive {:interrupt, %{name: "doorbell", url: url}}
      assert url =~ "bell.html?who=Ada"
      # Successful starts log at info, below the test level; failures warn.
      assert log =~
               ~s(interrupt "doorbell" of hall from deepcyber/lobby/interrupts/doorbell: no such interrupt)

      assert %{"doorbell" => %{source: :mqtt, status: 202}} = Interrupts.last("lobby")
    end

    test "retained messages and topics nobody subscribed to are dropped" do
      :ok = Interrupts.subscribe("lobby")

      assert InterruptMessage.dispatch("deepcyber/lobby/interrupts/doorbell", "", true) == []
      assert InterruptMessage.dispatch("elsewhere/doorbell", "", false) == []
      refute_receive {:interrupt, _payload}
      assert Interrupts.last("lobby") == %{}
    end

    test "a broken payload is recorded where the interrupt exists" do
      capture_log(fn ->
        assert [
                 {"hall", {:error, :not_found}},
                 {"lobby", {:error, {:invalid, ["the payload is not JSON"]}}}
               ] = InterruptMessage.dispatch("deepcyber/lobby/interrupts/doorbell", "who", false)
      end)

      assert %{"doorbell" => %{source: :mqtt, status: 422, reasons: ["the payload is not JSON"]}} =
               Interrupts.last("lobby")
    end

    test "names that cannot be interrupt names are dropped" do
      log =
        capture_log(fn ->
          assert InterruptMessage.dispatch("deepcyber/lobby/interrupts/Door Bell", "", false) ==
                   []
        end)

      assert log =~
               ~s("Door Bell" on deepcyber/lobby/interrupts/Door Bell is not an interrupt name)
    end

    test "the rate limit applies" do
      capture_log(fn ->
        topic = "deepcyber/lobby/interrupts/doorbell"
        assert [_hall, {"lobby", {:ok, _}}] = InterruptMessage.dispatch(topic, "", false)

        assert [_hall, {"lobby", {:error, :too_many}}] =
                 InterruptMessage.dispatch(topic, "", false)
      end)
    end
  end
end
