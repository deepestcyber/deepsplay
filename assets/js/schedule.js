// Time windows for the screen rotation (ADR 25): which pages are active, which
// override is shown, and for how long. Pure functions, used by the rotation
// hook in the shell and tested in Node (test/js/schedule_test.mjs).
//
// Windows come from the server (Deepsplay.TimeWindow.to_plan/1):
//   { start, end: "YYYY-MM-DDTHH:MM:SS" | null,
//     dates: [[spec, spec], ...] | null,   spec: {year?, month?, day}
//     days: [1..7] | null,                  1 = Monday
//     from, until: minutes 0..1440 | null }
// A list of windows is active if any matches; null (no `when`) always is.
// Times are the screen's local time. The same rules run in Elixir; both are
// tested against test/support/fixtures/time_window_cases.json.

function localDate(iso) {
  const [date, time = "00:00:00"] = iso.split("T")
  const [y, mo, d] = date.split("-").map(Number)
  const [h, mi] = time.split(":").map(Number)
  return new Date(y, mo - 1, d, h, mi)
}

function addDays(date, days) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + days)
}

const weekday = date => ((date.getDay() + 6) % 7) + 1

function inCycle(value, first, last) {
  return first <= last ? value >= first && value <= last : value >= first || value <= last
}

function inDates([a, b], date) {
  if (a.year !== undefined) {
    const day = new Date(date.getFullYear(), date.getMonth(), date.getDate())
    return day >= new Date(a.year, a.month - 1, a.day) && day <= new Date(b.year, b.month - 1, b.day)
  }
  if (a.month !== undefined) {
    const key = (month, day) => month * 100 + day
    return inCycle(key(date.getMonth() + 1, date.getDate()), key(a.month, a.day), key(b.month, b.day))
  }
  return inCycle(date.getDate(), a.day, b.day)
}

function dayMatches(w, date) {
  return (!w.days || w.days.includes(weekday(date))) && (!w.dates || w.dates.some(range => inDates(range, date)))
}

function inPeriod(w, date) {
  if (w.start && date < localDate(w.start)) return false
  if (w.end && date >= localDate(w.end)) return false
  return true
}

function inDayAndTime(w, date) {
  const minute = date.getHours() * 60 + date.getMinutes()
  const from = w.from ?? 0
  const until = w.until ?? 1440
  if (from <= until) return minute >= from && minute < until && dayMatches(w, date)
  // Overnight: the evening part is that day's, the morning part the previous day's.
  if (minute >= from) return dayMatches(w, date)
  if (minute < until) return dayMatches(w, addDays(date, -1))
  return false
}

export function active(windows, date) {
  if (!windows) return true
  return windows.some(w => inPeriod(w, date) && inDayAndTime(w, date))
}

// Indices of the entries (pages) whose windows are active.
export function activeIndices(entries, date) {
  return entries.map((entry, i) => i).filter(i => active(entries[i].when, date))
}

// The override to show: the active one with the highest priority, the first
// of equal ones; -1 for none.
export function currentOverride(overrides, date) {
  let best = -1
  overrides.forEach((override, i) => {
    if (active(override.when, date) && (best < 0 || override.priority > overrides[best].priority)) best = i
  })
  return best
}

// Milliseconds until the windows stop being active, looking ahead at most
// `limitMinutes`; null if they stay active beyond that. Boundaries fall on
// full minutes.
export function remainingMs(windows, date, limitMinutes = 7 * 1440) {
  const start = new Date(date.getFullYear(), date.getMonth(), date.getDate(), date.getHours(), date.getMinutes())
  for (let minutes = 1; minutes <= limitMinutes; minutes++) {
    const next = new Date(start.getTime() + minutes * 60000)
    if (!active(windows, next)) return next.getTime() - date.getTime()
  }
  return null
}

// Milliseconds until the next full minute, when windows can change.
export function msToNextMinute(date) {
  return 60000 - (date.getSeconds() * 1000 + date.getMilliseconds())
}
