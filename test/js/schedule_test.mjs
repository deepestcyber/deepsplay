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
