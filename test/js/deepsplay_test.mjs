// Tests the built page helper (priv/lib/deepsplay.js) against the shared
// parameter cases, and its API. Run by test/deepsplay/page_helper_js_test.exs.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const root = new URL("../../", import.meta.url)
const source = readFileSync(new URL("priv/lib/deepsplay.js", root), "utf8")
const cases = JSON.parse(readFileSync(new URL("test/support/fixtures/params_cases.json", root), "utf8"))

// Loads the helper in a fresh page with the given block, query and path.
function load({ toml = null, search = "", pathname = "/c/lobby/r/abc/page.html" } = {}) {
  const warnings = []
  const block = toml === null ? null : { type: "application/toml", textContent: toml }
  const context = {
    console: { warn: (...args) => warnings.push(args.join(" ")) },
    location: { search, pathname },
    document: { getElementById: id => (id === "deepsplay-page" ? block : null) },
    URLSearchParams,
  }
  context.window = context
  vm.runInNewContext(source, context)
  return { Deepsplay: context.window.Deepsplay, warnings }
}

const plain = value => JSON.parse(JSON.stringify(value))
let failures = 0

for (const c of cases) {
  try {
    const { Deepsplay } = load({ toml: c.toml, search: c.query })
    assert.deepEqual(plain(Deepsplay.params()), c.expect)

    // A helper with the same definition reads the same values.
    const fresh = load({ search: c.query }).Deepsplay
    assert.deepEqual(plain(fresh.helper("h", c.toml)), c.expect)
  } catch (error) {
    failures++
    console.error(`case "${c.name}": ${error.message}`)
  }
}

function check(name, fn) {
  try {
    fn()
  } catch (error) {
    failures++
    console.error(`${name}: ${error.message}`)
  }
}

check("params(name) returns a registered helper's values", () => {
  const { Deepsplay } = load({ search: "?theme=neon" })
  const t = Deepsplay.helper("theme", '[params.theme]\ntype = "enum"\nvalues = ["default", "neon"]\ndefault = "default"')
  assert.deepEqual(plain(t), { theme: "neon" })
  assert.equal(Deepsplay.params("theme"), t)
})

check("params(name) of an unknown helper is empty, with a warning", () => {
  const { Deepsplay, warnings } = load()
  assert.deepEqual(plain(Deepsplay.params("nope")), {})
  assert.ok(warnings.some(w => w.includes('helper "nope" is not registered')))
})

check("a second registration of a name keeps the first", () => {
  const { Deepsplay, warnings } = load({ search: "?n=5" })
  Deepsplay.helper("x", '[params.n]\ntype = "int"')
  const again = Deepsplay.helper("x", '[params.m]\ntype = "int"')
  assert.deepEqual(plain(again), { n: 5 })
  assert.ok(warnings.some(w => w.includes("registered twice")))
})

check("invalid TOML in the page block gives no parameters and a warning", () => {
  const { Deepsplay, warnings } = load({ toml: "[params.x", search: "?x=1" })
  assert.deepEqual(plain(Deepsplay.params()), {})
  assert.ok(warnings.some(w => w.includes("invalid TOML")))
})

check("a page without block has no parameters", () => {
  const { Deepsplay } = load({ search: "?x=1" })
  assert.deepEqual(plain(Deepsplay.params()), {})
})

check("api() builds upstream URLs from the page's configuration", () => {
  const { Deepsplay } = load({ pathname: "/c/lobby/r/3f2a/weather/deep/index.html" })
  assert.equal(Deepsplay.api("weather", "/current?city=berlin"), "/c/lobby/api/weather/current?city=berlin")
  assert.equal(Deepsplay.api("weather", "current"), "/c/lobby/api/weather/current")
  assert.equal(Deepsplay.api("weather"), "/c/lobby/api/weather")
})

check("api() outside deepsplay throws", () => {
  const { Deepsplay } = load({ pathname: "/local/page.html" })
  assert.throws(() => Deepsplay.api("weather", "/x"), /not served by deepsplay/)
})

check("version and a frozen API", () => {
  const { Deepsplay } = load()
  assert.match(Deepsplay.version, /^\d+\.\d+\.\d+$/)
  assert.ok(Object.isFrozen(Deepsplay))
})

if (failures > 0) {
  console.error(`${failures} failure(s)`)
  process.exit(1)
}
console.log(`ok: ${cases.length} cases and API checks`)
