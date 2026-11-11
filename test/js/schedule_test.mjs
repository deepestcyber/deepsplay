// Tests assets/js/schedule.js against the shared time window cases, converted
// by Deepsplay.ScheduleJsTest into the form the server sends to screens.
// Arguments: path of schedule.mjs (a copy of schedule.js), path of the cases.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { pathToFileURL } from "node:url"

const [modulePath, casesPath] = process.argv.slice(2)
const S = await import(pathToFileURL(modulePath).href)
const cases = JSON.parse(readFileSync(casesPath, "utf8"))

const at = text => {
  const [date, time] = text.split("T")
  const [y, mo, d] = date.split("-").map(Number)
  const [h, mi, s = 0] = time.split(":").map(Number)
  return new Date(y, mo - 1, d, h, mi, s)
}

let failures = 0
function check(name, fn) {
  try {
    fn()
  } catch (error) {
    failures++
    console.error(`${name}: ${error.message}`)
  }
}

for (const c of cases) {
  check(`case "${c.name}"`, () => {
    for (const [time, expected] of c.checks) assert.equal(S.active(c.windows, at(time)), expected, time)
  })
}

const daily = [{ start: null, end: null, dates: null, days: null, from: 28800, until: 54000 }]
const evening = [{ start: null, end: null, dates: null, days: null, from: 64800, until: null }]

check("no windows: always active", () => assert.equal(S.active(null, at("2027-01-01T00:00")), true))

check("activeIndices", () => {
  const pages = [{ when: null }, { when: daily }, { when: evening }]
  assert.deepEqual(S.activeIndices(pages, at("2027-01-04T09:00")), [0, 1])
  assert.deepEqual(S.activeIndices(pages, at("2027-01-04T19:00")), [0, 2])
})

check("currentOverride: highest priority, first on a tie, -1 for none", () => {
  const overrides = [
    { when: daily, priority: 0 },
    { when: daily, priority: 5 },
    { when: daily, priority: 5 },
    { when: evening, priority: 0 },
  ]
  assert.equal(S.currentOverride(overrides, at("2027-01-04T09:00")), 1)
  assert.equal(S.currentOverride(overrides, at("2027-01-04T19:00")), 3)
  assert.equal(S.currentOverride(overrides, at("2027-01-04T16:00")), -1)
  assert.equal(S.currentOverride([], at("2027-01-04T09:00")), -1)
})

check("currentOverride skips dismissed overrides until their window closes", () => {
  const overrides = [
    { url: "/a", when: daily, priority: 0 },
    { url: "/b", when: daily, priority: 5 },
  ]
  const nine = at("2027-01-04T09:00")
  const dismissed = S.dismiss(new Map(), overrides[1], nine)
  assert.equal(S.currentOverride(overrides, nine, dismissed), 0)
  // The same override in a new plan stays dismissed.
  assert.equal(S.currentOverride(overrides.map(o => ({ ...o })), at("2027-01-04T12:00"), dismissed), 0)
  // Its window closes at 15:00; the next day it is back.
  assert.equal(dismissed.get(S.overrideKey(overrides[1])), at("2027-01-04T15:00").getTime())
  assert.equal(S.currentOverride(overrides, at("2027-01-05T09:00"), dismissed), 1)
  // Running out dismissals are dropped on the next dismissal.
  S.dismiss(dismissed, overrides[0], at("2027-01-05T09:00"))
  assert.deepEqual([...dismissed.keys()], [S.overrideKey(overrides[0])])
})

check("acceptsInterrupt: equal or higher replaces, lower is ignored", () => {
  assert.equal(S.acceptsInterrupt(0, null), true)
  assert.equal(S.acceptsInterrupt(-5, null), true)
  assert.equal(S.acceptsInterrupt(10, 5), true)
  // equal: also the same interrupt again, which starts fresh
  assert.equal(S.acceptsInterrupt(5, 5), true)
  assert.equal(S.acceptsInterrupt(4, 5), false)
})

check("overrideOpened: a new active override of equal or higher priority", () => {
  const morning = [{ ...daily[0], from: 32400, until: 36000 }] // 09:00-10:00
  const overrides = [
    { url: "/low", when: morning, priority: 1 },
    { url: "/high", when: morning, priority: 10 },
    { url: "/old", when: daily, priority: 50 },
  ]
  const before = S.activeOverrideKeys(overrides, at("2027-01-04T08:59"))
  assert.deepEqual([...before], [S.overrideKey(overrides[2])])
  const nine = at("2027-01-04T09:00")
  // /high opens with 10: replaces an interrupt of 10 or less, not of 11
  assert.equal(S.overrideOpened(overrides, nine, new Map(), before, 10), true)
  assert.equal(S.overrideOpened(overrides, nine, new Map(), before, 11), false)
  // /old was active before: it does not count, whatever its priority
  assert.equal(S.overrideOpened(overrides, nine, new Map(), before, 50), false)
  // nothing new since the last check
  const after = S.activeOverrideKeys(overrides, nine)
  assert.equal(S.overrideOpened(overrides, at("2027-01-04T09:30"), new Map(), after, 0), false)
  // a dismissed override is not active
  const dismissed = S.dismiss(new Map(), overrides[1], nine)
  assert.equal(S.overrideOpened(overrides, nine, dismissed, before, 10), false)
  // an override in a new plan counts as opened (keys survive identical plans)
  const newPlan = [...overrides.map(o => ({ ...o })), { url: "/new", when: daily, priority: 3 }]
  assert.equal(S.overrideOpened(newPlan, at("2027-01-04T12:00"), new Map(), S.activeOverrideKeys(overrides, at("2027-01-04T12:00")), 3), true)
})

check("an override replaced by an interrupt comes back while its window is open", () => {
  // Nothing is dismissed by an interrupt: currentOverride still finds it.
  const overrides = [{ url: "/a", when: daily, priority: 0 }]
  assert.equal(S.currentOverride(overrides, at("2027-01-04T12:00")), 0)
  assert.equal(S.currentOverride(overrides, at("2027-01-04T16:00")), -1)
})

check("remainingMs until the window closes", () => {
  const now = new Date(2027, 0, 4, 14, 58, 30)
  assert.equal(S.remainingMs(daily, now), 90000)
  assert.equal(S.remainingMs(null, now), null)
  assert.equal(S.remainingMs([{ start: null, end: null, dates: null, days: null, from: null, until: null }], now, 2), null)
})

check("remainingMs to the second, over midnight and to a period's end", () => {
  const countdown = [{ start: null, end: null, dates: null, days: null, from: 86390, until: 5 }]
  assert.equal(S.remainingMs(countdown, new Date(2027, 0, 4, 23, 59, 55, 500)), 9500)
  const period = [{ start: "2027-01-04T10:00:00", end: "2027-01-04T10:00:42", dates: null, days: null, from: null, until: null }]
  assert.equal(S.remainingMs(period, new Date(2027, 0, 4, 10, 0, 40)), 2000)
  // Two windows back to back count as one.
  const joined = [
    { start: null, end: null, dates: null, days: null, from: 36000, until: 36030 },
    { start: null, end: null, dates: null, days: null, from: 36030, until: 36060 },
  ]
  assert.equal(S.remainingMs(joined, new Date(2027, 0, 4, 10, 0, 10)), 50000)
})

check("secondPrecise", () => {
  assert.equal(S.secondPrecise(daily), false)
  assert.equal(S.secondPrecise(null), false)
  assert.equal(S.secondPrecise([{ ...daily[0], until: 54015 }]), true)
  assert.equal(S.secondPrecise([{ ...daily[0], start: "2027-01-04T10:00:05" }]), true)
  assert.equal(S.secondPrecise([{ ...daily[0], start: "2027-01-04T10:00:00" }]), false)
})

check("msToNextCheck", () => {
  const date = new Date(2027, 0, 4, 14, 58, 30, 250)
  assert.equal(S.msToNextCheck(date, false), 29750)
  assert.equal(S.msToNextCheck(date, true), 750)
})

if (failures > 0) {
  console.error(`${failures} failure(s)`)
  process.exit(1)
}
console.log(`ok: ${cases.length} cases and schedule checks`)
