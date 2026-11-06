defmodule Deepsplay.StatusTest do
  # Not async: the status table is global.
  use ExUnit.Case, async: false

  alias Deepsplay.Status

  setup do
    Status.clear()
    :ok
  end

  defp sync, do: :sys.get_state(Status)

  test "update/2 merges, announces and logs new errors once" do
    Status.subscribe_all()
    now = DateTime.utc_now()

    Status.update("lobby", %{checked_at: now})
    assert_receive {:status_changed, "lobby"}
    assert %{checked_at: ^now, error: nil} = Status.get("lobby")

    Status.update("lobby", %{error: "fetch failed: x", error_at: now})
    Status.update("lobby", %{error: "fetch failed: x", error_at: now})
    Status.update("kitchen", %{error: "check failed: y", error_at: now})
    sync()

    assert [
             %{config: "kitchen", message: "check failed: y"},
             %{config: "lobby", message: "fetch failed: x"}
           ] = Status.recent_errors()
  end

  test "the log keeps the 50 newest errors" do
    for n <- 1..60, do: Status.update("lobby", %{error: "error #{n}"})
    sync()

    errors = Status.recent_errors()
    assert length(errors) == 50
    assert hd(errors).message == "error 60"
  end
end
