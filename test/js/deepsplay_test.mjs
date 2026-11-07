// Tests the built page helper (priv/lib/deepsplay.js) against the shared
// parameter cases, and its API. Run by test/deepsplay/page_helper_js_test.exs.
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const root = new URL("../../", import.meta.url)
const source = readFileSync(new URL("priv/lib/deepsplay.js", root), "utf8")
const cases = JSON.parse(readFileSync(new URL("test/support/fixtures/params_cases.json", root), "utf8"))

// A fetch answering from an in-memory state store like the server's, and
// recording requests.
function stateServer() {
  const store = new Map()
  const requests = []
  let seq = 0
  let interfere = 0

  const reply = (status, body, version) => ({
    ok: status >= 200 && status < 300,
    status,
    headers: { get: name => (name === "ETag" && version ? `"${version}"` : null) },
    json: async () => body,
  })

  async function fetch(url, init) {
    requests.push({ url, ...init })
    const { pathname, searchParams } = new URL(url, "http://screen")
    const key = pathname.replace(/^\/c\/[^/]+\/state\/?/, "").split("/").map(decodeURIComponent).join("/")
    const headers = init.headers || {}
    const current = store.get(key)

    if (init.method === "GET" && key === "") {
      const prefix = searchParams.get("prefix") || ""
      const keys = [...store].filter(([k]) => k.startsWith(prefix)).map(([k, e]) => ({ key: k, version: e.version }))
      return reply(200, { keys })
    }
    if (init.method === "GET") return current ? reply(200, current.value, current.version) : reply(404, { error: "no value" })
    if (init.method === "DELETE") {
      store.delete(key)
      return reply(204, null)
    }
    if (init.method === "POST") {
      const value = (current ? current.value : 0) + JSON.parse(init.body).increment
      store.set(key, { value, version: ++seq })
      return reply(200, { value, version: seq }, seq)
    }
    // PUT; `interfere` simulates other screens writing first.
    if (interfere > 0) {
      interfere--
      store.set(key, { value: (current ? current.value : 0) + 100, version: ++seq })
      return reply(412, { error: "version does not match" })
    }
    if (headers["If-None-Match"] === "*" && current) return reply(412, { error: "version does not match" })
    if (headers["If-Match"] && (!current || headers["If-Match"] !== `"${current.version}"`)) {
      return reply(412, { error: "version does not match" })
    }
    store.set(key, { value: JSON.parse(init.body), version: ++seq })
    return reply(200, { version: seq }, seq)
  }

  return { fetch, store, requests, interfereNext: n => (interfere = n) }
}

// Loads the helper in a fresh page with the given block, query and path.
function load({ toml = null, search = "", pathname = "/c/lobby/r/abc/page.html", fetch } = {}) {
  const warnings = []
  const block = toml === null ? null : { type: "application/toml", textContent: toml }
  const context = {
    console: { warn: (...args) => warnings.push(args.join(" ")) },
    location: { search, pathname },
    document: { getElementById: id => (id === "deepsplay-page" ? block : null) },
    URLSearchParams,
    fetch,
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

async function checkAsync(name, fn) {
  try {
    await fn()
  } catch (error) {
    failures++
    console.error(`${name}: ${error.message}`)
  }
}

await checkAsync("state: set, get, entry, list, delete", async () => {
  const server = stateServer()
  const { state } = load({ fetch: server.fetch }).Deepsplay

  assert.equal(await state.get("life/gen"), undefined)
  assert.equal(await state.entry("life/gen"), null)
  assert.equal(await state.set("life/gen", { n: 1 }), 1)
  assert.deepEqual(plain(await state.get("life/gen")), { n: 1 })
  assert.deepEqual(plain(await state.entry("life/gen")), { value: { n: 1 }, version: 1 })
  await state.set("shared/msg", "hi")
  assert.deepEqual(plain(await state.list("life/")), [{ key: "life/gen", version: 1 }])
  await state.delete("life/gen")
  assert.equal(await state.get("life/gen"), undefined)

  const put = server.requests.find(r => r.method === "PUT")
  assert.equal(put.url, "/c/lobby/state/life/gen")
  assert.equal(put.headers["Content-Type"], "application/json")
  assert.equal(put.body, '{"n":1}')
})

await checkAsync("state: keys are encoded per segment", async () => {
  const server = stateServer()
  const { state } = load({ fetch: server.fetch, pathname: "/c/lobby/r/abc/deep/er/page.html" }).Deepsplay
  await state.set("a b/c", 1)
  assert.equal(server.requests[0].url, "/c/lobby/state/a%20b/c")
})

await checkAsync("state: conditional writes reject with status 412", async () => {
  const server = stateServer()
  const { state } = load({ fetch: server.fetch }).Deepsplay
  const version = await state.set("k", 1, { onlyNew: true })
  await assert.rejects(state.set("k", 2, { onlyNew: true }), error => error.status === 412)
  await assert.rejects(state.set("k", 2, { ifVersion: version + 5 }), /412/)
  assert.equal(await state.set("k", 2, { ifVersion: version }), version + 1)
  assert.equal(server.requests.at(-1).headers["If-Match"], `"${version}"`)
})

await checkAsync("state: increment", async () => {
  const server = stateServer()
  const { state } = load({ fetch: server.fetch }).Deepsplay
  assert.equal(await state.increment("visits"), 1)
  assert.equal(await state.increment("visits", 5), 6)
})

await checkAsync("state: update retries when someone else wrote first", async () => {
  const server = stateServer()
  const { state } = load({ fetch: server.fetch }).Deepsplay
  assert.equal(await state.update("list", old => (old || 0) + 1), 1)

  server.interfereNext(2)
  // Two other writers add 100 each before this update gets through.
  assert.equal(await state.update("list", old => old + 1), 202)
  assert.equal(server.store.get("list").value, 202)

  server.interfereNext(20)
  await assert.rejects(state.update("list", old => old + 1), error => error.status === 412)
})

await checkAsync("state outside deepsplay throws", async () => {
  const { state } = load({ pathname: "/page.html", fetch: stateServer().fetch }).Deepsplay
  await assert.rejects(state.get("k"), /not served by deepsplay/)
})

if (failures > 0) {
  console.error(`${failures} failure(s)`)
  process.exit(1)
}
console.log(`ok: ${cases.length} cases and API checks`)
