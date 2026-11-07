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
//   Deepsplay.api(upstream, path) URL of an upstream of the page's
//                                 configuration (ADR 8)
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

function pageDefinitions() {
  const block = document.getElementById(BLOCK_ID)
  if (!block || block.type !== "application/toml") return {}
  return definitionsFrom(block.textContent, "page block")
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

function api(upstream, path = "") {
  const match = /^\/c\/([^/]+)\//.exec(location.pathname)
  if (!match) throw new Error("Deepsplay.api: the page is not served by deepsplay")
  const rest = path === "" || path.startsWith("/") ? path : "/" + path
  return `/c/${match[1]}/api/${encodeURIComponent(upstream)}${rest}`
}

window.Deepsplay = Object.freeze({ version: VERSION, params, helper, api })
