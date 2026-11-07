defmodule Deepsplay.ScheduleJsTest do
  # Runs the JavaScript tests of assets/js/schedule.js with Node, against the
  # same time window cases as Deepsplay.TimeWindowTest, converted to the form
  # the server sends to screens. Excluded when Node is not installed.
  use ExUnit.Case, async: true

  alias Deepsplay.TimeWindow

  @moduletag :node
  @moduletag :tmp_dir

  test "schedule.js passes the shared time window cases", %{tmp_dir: tmp_dir} do
    cases =
      "test/support/fixtures/time_window_cases.json"
      |> File.read!()
      |> Jason.decode!()
      |> Enum.map(fn c ->
        {:ok, %{"when" => value}} = TomlElixir.decode(c["toml"])
        {:ok, windows} = TimeWindow.parse(value)
        %{name: c["name"], windows: TimeWindow.to_plan(windows), checks: c["checks"]}
      end)

    module = Path.join(tmp_dir, "schedule.mjs")
    File.cp!("assets/js/schedule.js", module)
    cases_path = Path.join(tmp_dir, "cases.json")
    File.write!(cases_path, Jason.encode!(cases))

    {output, status} =
      System.cmd("node", ["test/js/schedule_test.mjs", module, cases_path],
        stderr_to_stdout: true,
        env: [{"TZ", "UTC"}]
      )

    assert status == 0, output
  end
end
