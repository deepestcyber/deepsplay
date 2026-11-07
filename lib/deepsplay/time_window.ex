defmodule Deepsplay.TimeWindow do
  @moduledoc """
  Time windows for pages and overrides in manifests (ADR 25).

  `when` is one window (a table) or a list of windows. Something is active if
  any of its windows matches; a window matches if all of its fields match.
  Fields, all optional:

    * `start`, `end` - one continuous period: `YYYY-MM-DD` or
      `YYYY-MM-DD HH:MM` (also with `T`); a start is included, an end
      excluded
    * `dates` - `YYYY-MM-DD`, `MM-DD` (every year) or `DD` (every month);
      ranges with `..` (both ends of the same form, wrapping over the end of
      a year or month if the first is later); or a list of these
    * `days` - weekdays `mon` to `sun`, a list or a range (`"mon-fri"`,
      wrapping like `"fri-mon"`)
    * `from`, `until` - daily time window `HH:MM`; `until` before `from` runs
      overnight, and the part after midnight belongs to the day it started
      (so `dates` and `days` are checked for that day); `until = "24:00"` is
      the end of the day

  Times are local, minute-precise; every boundary falls on a full minute.
  The same rules run in the browser (`assets/js/schedule.js`); both are
  tested against `test/support/fixtures/time_window_cases.json`.
  """

  @type date_spec :: {:full, Date.t()} | {:yearly, 1..12, 1..31} | {:monthly, 1..31}

  @type t :: %{
          start: NaiveDateTime.t() | nil,
          end: NaiveDateTime.t() | nil,
          dates: [{date_spec(), date_spec()}] | nil,
          days: [1..7] | nil,
          from: 0..1440 | nil,
          until: 0..1440 | nil,
          text: String.t()
        }

  @fields ~w(start end dates days from until)
  @weekdays %{"mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6, "sun" => 7}

  @doc """
  Parses a `when` value from TOML: one window or a list of windows.
  """
  @spec parse(term()) :: {:ok, [t()]} | {:error, String.t()}
  def parse(window) when is_map(window), do: parse([window])

  def parse([_ | _] = windows) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, acc} ->
      case window(window) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  def parse(_value), do: {:error, "must be a table or a list of tables"}

  defp window(window) when is_map(window) do
    unknown = Map.keys(window) -- @fields

    with [] <- unknown,
         {:ok, start} <- point(window["start"], "start", :start),
         {:ok, end_} <- point(window["end"], "end", :end),
         {:ok, dates} <- dates(window["dates"]),
         {:ok, days} <- days(window["days"]),
         {:ok, from} <- time(window["from"], "from"),
         {:ok, until} <- time(window["until"], "until") do
      cond do
        start && end_ && NaiveDateTime.compare(start, end_) != :lt ->
          {:error, "start must be before end"}

        from == 1440 ->
          {:error, ~s(from must be before 24:00)}

        true ->
          {:ok,
           %{
             start: start,
             end: end_,
             dates: dates,
             days: days,
             from: from,
             until: until,
             text: describe(window)
           }}
      end
    else
      [key | _] -> {:error, ~s(unknown key "#{key}")}
      {:error, message} -> {:error, message}
    end
  end

  defp window(_window), do: {:error, "must be a table or a list of tables"}

  # Points in time: a date alone is the start of that day.
  defp point(nil, _key, _which), do: {:ok, nil}

  defp point(value, key, _which) when is_binary(value) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}):(\d{2}))?$/, value) do
      [_all, date] ->
        with {:ok, date} <- Date.from_iso8601(date),
             do: {:ok, NaiveDateTime.new!(date, ~T[00:00:00])}

      [_all, date, hour, minute] ->
        with {:ok, date} <- Date.from_iso8601(date),
             {:ok, time} <- Time.new(String.to_integer(hour), String.to_integer(minute), 0) do
          {:ok, NaiveDateTime.new!(date, time)}
        end

      nil ->
        :error
    end
    |> case do
      {:ok, point} -> {:ok, point}
      _invalid -> {:error, ~s(#{key} must be "YYYY-MM-DD" or "YYYY-MM-DD HH:MM")}
    end
  end

  defp point(_value, key, _which),
    do: {:error, ~s(#{key} must be "YYYY-MM-DD" or "YYYY-MM-DD HH:MM")}

  defp dates(nil), do: {:ok, nil}
  defp dates(value) when is_binary(value), do: dates([value])

  defp dates([_ | _] = values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case date_range(value) do
        {:ok, range} ->
          {:cont, {:ok, acc ++ [range]}}

        :error ->
          {:halt,
           {:error,
            ~s(dates: "#{inspect_value(value)}" is not a date, MM-DD, DD or a range of one of them)}}
      end
    end)
  end

  defp dates(_value), do: {:error, "dates must be a string or a list of strings"}

  defp date_range(value) when is_binary(value) do
    case String.split(value, "..") do
      [single] ->
        with {:ok, spec} <- date_spec(single), do: {:ok, {spec, spec}}

      [first, last] ->
        with {:ok, a} <- date_spec(first),
             {:ok, b} <- date_spec(last),
             true <- elem(a, 0) == elem(b, 0),
             true <- elem(a, 0) != :full or Date.compare(elem(a, 1), elem(b, 1)) != :gt do
          {:ok, {a, b}}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp date_range(_value), do: :error

  defp date_spec(text) do
    case Regex.run(~r/^(?:(\d{4})-)?(?:(\d{2})-)?(\d{2})$/, String.trim(text)) do
      [_all, year, month, day] when year != "" and month != "" ->
        case Date.from_iso8601("#{year}-#{month}-#{day}") do
          {:ok, date} -> {:ok, {:full, date}}
          _invalid -> :error
        end

      [_all, "", month, day] when month != "" ->
        {m, d} = {String.to_integer(month), String.to_integer(day)}
        if m in 1..12 and d in 1..days_in_month(m), do: {:ok, {:yearly, m, d}}, else: :error

      [_all, "", "", day] ->
        d = String.to_integer(day)
        if d in 1..31, do: {:ok, {:monthly, d}}, else: :error

      _other ->
        :error
    end
  end

  # February counts 29 days, so 02-29 is valid (it matches in leap years).
  defp days_in_month(2), do: 29
  defp days_in_month(month) when month in [4, 6, 9, 11], do: 30
  defp days_in_month(_month), do: 31

  defp days(nil), do: {:ok, nil}

  defp days(value) when is_binary(value) do
    case String.split(value, "-") do
      [day] ->
        with {:ok, n} <- weekday(day), do: {:ok, [n]}

      [first, last] ->
        with {:ok, a} <- weekday(first), {:ok, b} <- weekday(last) do
          {:ok,
           if(a <= b, do: Enum.to_list(a..b), else: Enum.to_list(a..7) ++ Enum.to_list(1..b))}
        end

      _other ->
        {:error, ~s(days: "#{value}" is not a weekday or a range like "mon-fri")}
    end
  end

  defp days([_ | _] = values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case is_binary(value) && days(value) do
        {:ok, list} -> {:cont, {:ok, Enum.uniq(acc ++ list)}}
        {:error, message} -> {:halt, {:error, message}}
        false -> {:halt, {:error, "days must be strings"}}
      end
    end)
  end

  defp days(_value), do: {:error, "days must be a string or a list of strings"}

  defp weekday(text) do
    case Map.fetch(@weekdays, String.trim(text)) do
      {:ok, n} -> {:ok, n}
      :error -> {:error, ~s(days: "#{text}" is not one of mon, tue, wed, thu, fri, sat, sun)}
    end
  end

  defp time(nil, _key), do: {:ok, nil}

  defp time(value, key) when is_binary(value) do
    case Regex.run(~r/^(\d{2}):(\d{2})$/, value) do
      [_all, "24", "00"] ->
        {:ok, 1440}

      [_all, hour, minute] ->
        {h, m} = {String.to_integer(hour), String.to_integer(minute)}
        if h < 24 and m < 60, do: {:ok, h * 60 + m}, else: {:error, ~s(#{key} must be "HH:MM")}

      nil ->
        {:error, ~s[#{key} must be "HH:MM" (24-hour)]}
    end
  end

  defp time(_value, key), do: {:error, ~s[#{key} must be "HH:MM" (24-hour)]}

  defp inspect_value(value) when is_binary(value), do: value
  defp inspect_value(value), do: inspect(value)

  # A short text for the catalog, from the fields as written.
  defp describe(window) do
    @fields
    |> Enum.filter(&Map.has_key?(window, &1))
    |> Enum.map_join(", ", fn key ->
      value = window[key]
      "#{key} #{if is_list(value), do: Enum.join(value, " "), else: value}"
    end)
    |> case do
      "" -> "always"
      text -> text
    end
  end

  @doc """
  Returns true if any of the windows matches the local time `at`. `nil` (no
  `when`) is always active.
  """
  @spec active?([t()] | nil, NaiveDateTime.t()) :: boolean()
  def active?(nil, _at), do: true
  def active?(windows, at), do: Enum.any?(windows, &matches?(&1, at))

  defp matches?(window, at) do
    in_period?(window, at) and in_day_and_time?(window, at)
  end

  defp in_period?(window, at) do
    (window.start == nil or NaiveDateTime.compare(at, window.start) != :lt) and
      (window.end == nil or NaiveDateTime.compare(at, window.end) == :lt)
  end

  defp in_day_and_time?(window, at) do
    minute = at.hour * 60 + at.minute
    date = NaiveDateTime.to_date(at)
    from = window.from || 0
    until = window.until || 1440

    cond do
      from <= until ->
        minute >= from and minute < until and day_matches?(window, date)

      # Overnight: the evening part is that day's, the morning part the
      # previous day's.
      minute >= from ->
        day_matches?(window, date)

      minute < until ->
        day_matches?(window, Date.add(date, -1))

      true ->
        false
    end
  end

  defp day_matches?(window, date) do
    (window.days == nil or Date.day_of_week(date) in window.days) and
      (window.dates == nil or Enum.any?(window.dates, &in_dates?(&1, date)))
  end

  defp in_dates?({{:full, first}, {:full, last}}, date),
    do: Date.compare(date, first) != :lt and Date.compare(date, last) != :gt

  defp in_dates?({{:yearly, m1, d1}, {:yearly, m2, d2}}, date),
    do: in_cycle?({date.month, date.day}, {m1, d1}, {m2, d2})

  defp in_dates?({{:monthly, d1}, {:monthly, d2}}, date), do: in_cycle?(date.day, d1, d2)

  # Within a range that may wrap over the end of the cycle.
  defp in_cycle?(value, first, last) when first <= last, do: value >= first and value <= last
  defp in_cycle?(value, first, last), do: value >= first or value <= last

  @doc """
  The windows as sent to the browser (see `assets/js/schedule.js`).
  """
  @spec to_plan([t()] | nil) :: [map()] | nil
  def to_plan(nil), do: nil

  def to_plan(windows) do
    Enum.map(windows, fn window ->
      %{
        start: window.start && NaiveDateTime.to_iso8601(window.start),
        end: window.end && NaiveDateTime.to_iso8601(window.end),
        dates: window.dates && Enum.map(window.dates, fn {a, b} -> [spec(a), spec(b)] end),
        days: window.days,
        from: window.from,
        until: window.until
      }
    end)
  end

  defp spec({:full, date}), do: %{year: date.year, month: date.month, day: date.day}
  defp spec({:yearly, month, day}), do: %{month: month, day: day}
  defp spec({:monthly, day}), do: %{day: day}

  @doc """
  The windows as short text for the catalog.
  """
  @spec describe_all([t()] | nil) :: String.t()
  def describe_all(nil), do: "always"
  def describe_all(windows), do: Enum.map_join(windows, "; ", & &1.text)
end
