// Time windows for the screen rotation (ADR 25, 30): which pages are active, which
// override is shown, and for how long. Pure functions, used by the rotation
// hook in the shell and tested in Node (test/js/schedule_test.mjs).
//
// Windows come from the server (Deepsplay.TimeWindow.to_plan/1):
//   { start, end: "YYYY-MM-DDTHH:MM:SS" | null,
//     dates: [[spec, spec], ...] | null,   spec: {year?, month?, day}
//     days: [1..7] | null,                  1 = Monday
//     from, until: seconds of the day 0..86400 | null }
// A list of windows is active if any matches; null (no `when`) always is.
// Times are the screen's local time. The same rules run in Elixir; both are
// tested against test/support/fixtures/time_window_cases.json.

function localDate(iso) {
  const [date, time = "00:00:00"] = iso.split("T")
  const [y, mo, d] = date.split("-").map(Number)
  const [h, mi, s = 0] = time.split(":").map(Number)
  return new Date(y, mo - 1, d, h, mi, s)
}

const DAY = 86400

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
  const second = date.getHours() * 3600 + date.getMinutes() * 60 + date.getSeconds()
  const from = w.from ?? 0
  const until = w.until ?? DAY
  if (from <= until) return second >= from && second < until && dayMatches(w, date)
  // Overnight: the evening part is that day's, the morning part the previous day's.
  if (second >= from) return dayMatches(w, date)
  if (second < until) return dayMatches(w, addDays(date, -1))
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
// The index of the override shown at `date`: the active one with the
// highest priority, the first on a tie; -1 for none. Overrides dismissed on
// this screen (ADR 31) are skipped while their dismissal lasts.
export function currentOverride(overrides, date, dismissed = new Map()) {
  let best = -1
  overrides.forEach((override, i) => {
    if (!active(override.when, date) || dismissed.get(overrideKey(override)) > date.getTime()) return
    if (best < 0 || override.priority > overrides[best].priority) best = i
  })
  return best
}

// Interrupts (ADR 32). An incoming interrupt replaces what an override or
// another interrupt shows if its priority is equal or higher; `shown` is the
// priority of what is shown, or null for the rotation or the empty page.
export function acceptsInterrupt(priority, shown) {
  return shown === null || priority >= shown
}

// Keys of the overrides active at `date` and not dismissed.
export function activeOverrideKeys(overrides, date, dismissed = new Map()) {
  const keys = new Set()
  for (const override of overrides) {
    if (active(override.when, date) && !(dismissed.get(overrideKey(override)) > date.getTime())) {
      keys.add(overrideKey(override))
    }
  }
  return keys
}

// Whether an override became active since `previous` (keys from
// activeOverrideKeys) with a priority equal or higher than `priority`: it
// then replaces the interrupt shown.
export function overrideOpened(overrides, date, dismissed, previous, priority) {
  const now = activeOverrideKeys(overrides, date, dismissed)
  return overrides.some(o => o.priority >= priority && now.has(overrideKey(o)) && !previous.has(overrideKey(o)))
}

// Identifies an override across plans, so a dismissal survives a new plan
// with the same override.
export function overrideKey(override) {
  return JSON.stringify([override.url, override.when, override.priority])
}

// Dismisses an override on this screen until its current window closes
// (ADR 31). Drops dismissals that have run out.
export function dismiss(dismissed, override, date) {
  const now = date.getTime()
  for (const [key, until] of dismissed) if (until <= now) dismissed.delete(key)
  const remaining = remainingMs(override.when, date)
  dismissed.set(overrideKey(override), remaining === null ? Infinity : now + remaining)
  return dismissed
}

// The moments after `date`, up to `limitDays` ahead, at which the windows
// can change: their starts and ends, midnights, and the daily times.
function boundaries(windows, date, limitDays) {
  const points = []
  for (const w of windows) {
    if (w.start) points.push(localDate(w.start))
    if (w.end) points.push(localDate(w.end))
  }
  for (let day = 0; day <= limitDays; day++) {
    const y = date.getFullYear(), m = date.getMonth(), d = date.getDate() + day
    points.push(new Date(y, m, d))
    for (const w of windows) {
      for (const s of [w.from, w.until]) if (s != null) points.push(new Date(y, m, d, 0, 0, s))
    }
  }
  const end = addDays(date, limitDays + 1)
  return points.filter(p => p > date && p <= end).sort((a, b) => a - b)
}

// Milliseconds until the windows stop being active, looking ahead at most
// `limitDays`; null if they stay active beyond that.
export function remainingMs(windows, date, limitDays = 7) {
  if (!windows) return null
  for (const point of boundaries(windows, date, limitDays)) {
    if (!active(windows, point)) return point.getTime() - date.getTime()
  }
  return null
}

// True if any boundary of the windows has seconds.
export function secondPrecise(windows) {
  return (windows || []).some(
    w => [w.from, w.until].some(s => s != null && s % 60 !== 0) ||
      [w.start, w.end].some(p => p && !p.endsWith(":00"))
  )
}

// Milliseconds until the next moment windows can change: the next full
// second if `seconds`, otherwise the next full minute.
export function msToNextCheck(date, seconds) {
  if (seconds) return 1000 - date.getMilliseconds()
  return 60000 - (date.getSeconds() * 1000 + date.getMilliseconds())
}
