defmodule Deepsplay.TimeWindowTest do
  use ExUnit.Case, async: true

  alias Deepsplay.TimeWindow

  @cases "test/support/fixtures/time_window_cases.json" |> File.read!() |> Jason.decode!()

  def windows(toml) do
    {:ok, %{"when" => value}} = TomlElixir.decode(toml)
    {:ok, windows} = TimeWindow.parse(value)
    windows
  end

  describe "shared cases (same as schedule.js)" do
    for c <- @cases do
      @case c
      test @case["name"] do
        windows = windows(@case["toml"])

        for [at, expected] <- @case["checks"] do
          at = NaiveDateTime.from_iso8601!(at <> ":00")
          assert TimeWindow.active?(windows, at) == expected, "#{at}: expected #{expected}"
        end
      end
    end
  end

  test "no windows: always active" do
    assert TimeWindow.active?(nil, ~N[2027-01-01 00:00:00])
  end

  test "invalid windows" do
    for {value, message} <- [
          {"daily", "must be a table or a list of tables"},
          {[], "must be a table or a list of tables"},
          {%{"from" => "8:00"}, "from must be"},
          {%{"from" => "08:60"}, "from must be"},
          {%{"until" => "25:00"}, "until must be"},
          {%{"from" => "24:00"}, "from must be before 24:00"},
          {%{"start" => "2027-1-2"}, "start must be"},
          {%{"start" => "2027-01-02 4pm"}, "start must be"},
          {%{"start" => "2027-01-03", "end" => "2027-01-02"}, "start must be before end"},
          {%{"dates" => "2027-02-30"}, ~s(dates: "2027-02-30")},
          {%{"dates" => "12-24..2027-12-26"}, "dates:"},
          {%{"dates" => "2027-12-26..2027-12-24"}, "dates:"},
          {%{"dates" => "32"}, "dates:"},
          {%{"dates" => "13-01"}, "dates:"},
          {%{"days" => "monday"}, ~s(days: "monday")},
          {%{"days" => "mon-fri-sat"}, "days:"},
          {%{"days" => [1]}, "days must be strings"},
          {%{"hours" => "8"}, ~s(unknown key "hours")}
        ] do
      assert {:error, error} = TimeWindow.parse(value)
      assert error =~ message, "#{inspect(value)}: #{error}"
    end
  end

  test "describes windows as written" do
    assert TimeWindow.describe_all(
             windows(
               ~s(when = [{ days = "mon-fri", from = "08:00", until = "15:00" }, { dates = ["12-24", "13..15"] }])
             )
           ) ==
             "days mon-fri, from 08:00, until 15:00; dates 12-24 13..15"

    assert TimeWindow.describe_all(nil) == "always"
  end
end
