// deepsplay.js — the page helper deepsplay offers content pages (ADR 14, 15).
//
// Served at /lib/v1/deepsplay.js (compatible within v1) and
// /lib/deepsplay@X.Y.Z.js (one exact version). Load it before helpers and
// before the page's own code:
//
//   <script type="application/toml" id="deepsplay-page"> ... </script>
//   <script src="/lib/v1/deepsplay.js"></script>
//
// API, under the global `Deepsplay`:
//
//   Deepsplay.params()            the page's own parameters: typed, with
//                                 defaults applied and limits enforced
//   Deepsplay.params("theme")     the parameters of a registered helper
//   Deepsplay.helper(name, toml)  registers a helper's parameter definition
//                                 and returns its parameters
//   Deepsplay.page()              the page's metadata from its block
//                                 (ADR 24, 27): { title, description,
//                                 details, authors, credits, license }
//   Deepsplay.api(upstream, path) URL of an upstream of the page's
//                                 configuration (ADR 8)
//   Deepsplay.state               shared state of the page's configuration
//                                 (ADR 21); all functions return promises:
//     .get(key)                   the value, or undefined
//     .entry(key)                 { value, version }, or null
//     .set(key, value, opts)      stores; opts.ifVersion / opts.onlyNew make
//                                 it conditional; resolves to the version
//     .delete(key, opts)          deletes; opts.ifVersion as for set
//     .increment(key, by = 1)     adds to a number; resolves to the new value
//     .list(prefix = "")          [{ key, version }]
//     .update(key, fn)            new value = fn(old value or undefined),
//                                 written only if nobody wrote in between,
//                                 retried otherwise; resolves to it
//   Failed requests reject with an Error carrying `status` (412: someone
//   else wrote first).
//   Deepsplay.version             version of this helper
//
// The value rules here and in Deepsplay.PageDoc (Elixir) are the same; both
// are tested against test/support/fixtures/params_cases.json.

import { parse as parseToml } from "../vendor/smol-toml/parse.js"

const VERSION = __DEEPSPLAY_VERSION__
const BLOCK_ID = "deepsplay-page"
const UNITS = { ms: 1, s: 1000, m: 60000, h: 3600000 }
const TRUE = ["true", "1", "yes", "on", ""]
const FALSE = ["false", "0", "no", "off"]

const warn = (...args) => console.warn("deepsplay.js:", ...args)

// ---------- values ----------

function parseDuration(text) {
  const m = /^(\d+)(ms|s|m|h)$/.exec(text)
  if (!m) return undefined
  const ms = Number(m[1]) * UNITS[m[2]]
  return ms > 0 ? ms : undefined
}

function clamp(value, def) {
  if (def.min !== undefined && value < def.min) return def.min
  if (def.max !== undefined && value > def.max) return def.max
  return value
}

// Converts a URL value (a string) to the parameter's type, or undefined if it
// is not valid for it.
function cast(def, raw) {
  switch (def.type) {
    case "string":
      return raw
    case "int":
      return /^-?\d+$/.test(raw) ? clamp(parseInt(raw, 10), def) : undefined
    case "number":
      return /^-?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$/.test(raw) ? clamp(Number(raw), def) : undefined
    case "bool": {
      const v = raw.toLowerCase()
      if (TRUE.includes(v)) return true
      if (FALSE.includes(v)) return false
      return undefined
    }
    case "duration": {
      const ms = parseDuration(raw)
      return ms === undefined ? undefined : clamp(ms, def)
    }
    case "color":
      return castColor(raw)
    case "enum":
      return def.values.includes(raw) ? raw : undefined
  }
  return undefined
}

function castColor(raw) {
  const hex = /^#?([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(raw)
  if (hex) return "#" + hex[1].toLowerCase()
  if (/^[a-zA-Z]+$/.test(raw)) return raw.toLowerCase()
  return undefined
}

// ---------- definitions ----------

const isNumber = v => typeof v === "number" && Number.isFinite(v)

// A limit is a number, or a duration text for duration parameters.
function normalizeLimit(def, value, key, name) {
  if (value === undefined) return undefined
  if (def.type === "duration" && typeof value === "string") {
    const ms = parseDuration(value)
    if (ms !== undefined) return ms
  } else if (["int", "number", "duration"].includes(def.type) && isNumber(value)) {
    return value
  }
  warn(`parameter "${name}": invalid ${key}, ignored`)
  return undefined
}

// A default as written in TOML, converted like a URL value would be.
function normalizeDefault(def, value, name) {
  if (value === undefined) return undefined
  const text = typeof value === "boolean" || isNumber(value) ? String(value) : value
  const result = typeof text === "string" ? cast(def, text) : undefined
  if (result === undefined) warn(`parameter "${name}": invalid default, ignored`)
  return result
}

function normalizeParams(table) {
  const defs = {}
  if (table === undefined) return defs
  if (typeof table !== "object" || Array.isArray(table)) {
    warn("params must be a table")
    return defs
  }

  for (const [name, raw] of Object.entries(table)) {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      warn(`parameter "${name}" must be a table`)
      continue
    }
    const def = { type: raw.type }
    if (!["string", "int", "number", "bool", "duration", "color", "enum"].includes(def.type)) {
      warn(`parameter "${name}": unknown type ${JSON.stringify(raw.type)}`)
      continue
    }
    if (def.type === "enum") {
      const ok = Array.isArray(raw.values) && raw.values.length > 0
      if (!ok || !raw.values.every(v => typeof v === "string")) {
        warn(`parameter "${name}": enum needs a list of values`)
        continue
      }
      def.values = raw.values
    }
    def.min = normalizeLimit(def, raw.min, "min", name)
    def.max = normalizeLimit(def, raw.max, "max", name)
    def.default = normalizeDefault(def, raw.default, name)
    defs[name] = def
  }
  return defs
}

function definitionsFrom(toml, where) {
  try {
    return normalizeParams(parseToml(toml).params)
  } catch (error) {
    warn(`${where}: invalid TOML (${error.message})`)
    return {}
  }
}

// Reads the defined parameters from a query string.
function read(defs, search) {
  const query = new URLSearchParams(search)
  const values = {}
  for (const [name, def] of Object.entries(defs)) {
    let value = query.has(name) ? cast(def, query.get(name)) : undefined
    if (value === undefined) value = def.default
    if (value !== undefined) values[name] = value
  }
  return values
}

// ---------- API ----------

let pageValues = null
const helpers = {}

function pageBlock() {
  const block = document.getElementById(BLOCK_ID)
  return block && block.type === "application/toml" ? block.textContent : null
}

function pageDefinitions() {
  const toml = pageBlock()
  return toml === null ? {} : definitionsFrom(toml, "page block")
}

// ---------- metadata (ADR 24) ----------

const MAX_NAME = 200
const MAX_CREDITS = 500
const MAX_LICENSE = 100
const MAX_DETAILS = 5000

function metaText(data, key, max, where) {
  const value = data[key]
  if (value === undefined) return null
  if (typeof value !== "string") {
    warn(`${where}: ${key} must be a string`)
    return null
  }
  const text = value.trim()
  if (text === "") return null
  if ([...text].length > max) {
    warn(`${where}: ${key} must be at most ${max} characters`)
    return null
  }
  return text
}

function metaAuthors(value, where) {
  if (value === undefined) return []
  const names = typeof value === "string" ? [value] : value
  if (!Array.isArray(names) || !names.every(name => typeof name === "string")) {
    warn(`${where}: author must be a string or a list of strings`)
    return []
  }
  const kept = []
  for (const name of names.map(name => name.trim()).filter(name => name !== "")) {
    if ([...name].length <= MAX_NAME) kept.push(name)
    else warn(`${where}: author names must be at most ${MAX_NAME} characters`)
  }
  return kept
}

function metadataFrom(toml, fallbackTitle, where) {
  let data = {}
  if (toml !== null) {
    try {
      data = parseToml(toml)
    } catch (error) {
      warn(`${where}: invalid TOML (${error.message})`)
    }
  }
  const title = typeof data.title === "string" ? data.title : fallbackTitle || null
  const description = typeof data.description === "string" ? data.description : null
  return Object.freeze({
    title,
    description,
    details: metaText(data, "details", MAX_DETAILS, where),
    authors: Object.freeze(metaAuthors(data.author, where)),
    credits: metaText(data, "credits", MAX_CREDITS, where),
    license: metaText(data, "license", MAX_LICENSE, where),
  })
}

let pageMeta = null

function page() {
  if (pageMeta === null) pageMeta = metadataFrom(pageBlock(), document.title, "page block")
  return pageMeta
}

function params(helperName) {
  if (helperName !== undefined) {
    if (!(helperName in helpers)) warn(`helper "${helperName}" is not registered`)
    return helpers[helperName] || {}
  }
  if (pageValues === null) pageValues = read(pageDefinitions(), location.search)
  return pageValues
}

function helper(name, toml) {
  if (name in helpers) warn(`helper "${name}" is registered twice; the first one counts`)
  else helpers[name] = read(definitionsFrom(toml, `helper "${name}"`), location.search)
  return helpers[name]
}

function configBase(what) {
  const match = /^\/c\/([^/]+)\//.exec(location.pathname)
  if (!match) throw new Error(`Deepsplay.${what}: the page is not served by deepsplay`)
  return `/c/${match[1]}`
}

function api(upstream, path = "") {
  const rest = path === "" || path.startsWith("/") ? path : "/" + path
  return `${configBase("api")}/api/${encodeURIComponent(upstream)}${rest}`
}

// ---------- shared state (ADR 21) ----------

const UPDATE_ATTEMPTS = 10

function stateUrl(key = "") {
  return `${configBase("state")}/state/${key.split("/").map(encodeURIComponent).join("/")}`
}

async function stateRequest(method, key, { body, headers = {}, query = "" } = {}) {
  const init = { method, headers: { Accept: "application/json", ...headers }, cache: "no-store" }
  if (body !== undefined) {
    init.body = JSON.stringify(body)
    init.headers["Content-Type"] = "application/json"
  }
  const response = await fetch(stateUrl(key) + query, init)
  if (response.ok || (method === "GET" && response.status === 404)) return response

  let message = `${method} ${key}: ${response.status}`
  try {
    message += ` ${(await response.json()).error}`
  } catch {}
  const error = new Error(`Deepsplay.state: ${message}`)
  error.status = response.status
  throw error
}

function conditions({ ifVersion, onlyNew } = {}) {
  if (ifVersion !== undefined) return { "If-Match": `"${ifVersion}"` }
  if (onlyNew) return { "If-None-Match": "*" }
  return {}
}

const versionOf = response => Number((response.headers.get("ETag") || "").replace(/"/g, ""))

const state = Object.freeze({
  async entry(key) {
    const response = await stateRequest("GET", key)
    if (response.status === 404) return null
    return { value: await response.json(), version: versionOf(response) }
  },

  async get(key) {
    const entry = await state.entry(key)
    return entry === null ? undefined : entry.value
  },

  async set(key, value, opts = {}) {
    const response = await stateRequest("PUT", key, { body: value, headers: conditions(opts) })
    return (await response.json()).version
  },

  async delete(key, opts = {}) {
    await stateRequest("DELETE", key, { headers: conditions(opts) })
  },

  async increment(key, by = 1) {
    const response = await stateRequest("POST", key, { body: { increment: by } })
    return (await response.json()).value
  },

  async list(prefix = "") {
    const response = await stateRequest("GET", "", { query: `?prefix=${encodeURIComponent(prefix)}` })
    return (await response.json()).keys
  },

  async update(key, fn) {
    for (let attempt = 1; ; attempt++) {
      const entry = await state.entry(key)
      const value = fn(entry === null ? undefined : entry.value)
      const opts = entry === null ? { onlyNew: true } : { ifVersion: entry.version }
      try {
        await state.set(key, value, opts)
        return value
      } catch (error) {
        if (error.status !== 412 || attempt >= UPDATE_ATTEMPTS) throw error
      }
    }
  },
})

window.Deepsplay = Object.freeze({ version: VERSION, params, helper, page, api, state })
