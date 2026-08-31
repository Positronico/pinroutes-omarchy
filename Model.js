// Pure helpers for PinRoutes: IPv4/CIDR validation, network normalization,
// and matching rules against the kernel route table. Mirrors the macOS app's
// NetworkValidation + RouteManager verify logic, adapted to `ip -j route`.

function isIPv4(str) {
  var s = String(str || "").trim()
  var m = s.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
  if (!m) return false
  for (var i = 1; i <= 4; i++) {
    if (parseInt(m[i], 10) > 255) return false
  }
  return true
}

function parseCidr(str) {
  var s = String(str || "").trim()
  var parts = s.split("/")
  if (parts.length !== 2) return null
  if (!isIPv4(parts[0])) return null
  if (!/^\d{1,2}$/.test(parts[1])) return null
  var prefix = parseInt(parts[1], 10)
  if (prefix < 0 || prefix > 32) return null
  var octets = parts[0].split(".").map(function(o) { return parseInt(o, 10) })
  return { octets: octets, prefix: prefix }
}

// Zero the host bits so the stored rule matches what the kernel will report:
// "10.255.1.5/16" -> "10.255.0.0/16".
function normalizeCidr(str) {
  var parsed = parseCidr(str)
  if (!parsed) return null
  var addr = ((parsed.octets[0] * 16777216) + (parsed.octets[1] * 65536) + (parsed.octets[2] * 256) + parsed.octets[3]) >>> 0
  var mask = parsed.prefix === 0 ? 0 : (0xFFFFFFFF << (32 - parsed.prefix)) >>> 0
  var net = (addr & mask) >>> 0
  var o = [(net >>> 24) & 255, (net >>> 16) & 255, (net >>> 8) & 255, net & 255]
  return o.join(".") + "/" + parsed.prefix
}

// `ip -j route show` prints a /32 destination as the bare address.
function dstKey(normalizedCidr) {
  var parsed = parseCidr(normalizedCidr)
  if (!parsed) return String(normalizedCidr)
  if (parsed.prefix === 32) return String(normalizedCidr).split("/")[0]
  return String(normalizedCidr)
}

function validateRule(name, network, gateway) {
  if (String(name || "").trim() === "") return { ok: false, error: "Name is required" }
  var normalized = normalizeCidr(network)
  if (!normalized) return { ok: false, error: "Network must be IPv4 CIDR, e.g. 10.255.0.0/16" }
  if (!isIPv4(gateway)) return { ok: false, error: "Gateway must be an IPv4 address, e.g. 10.0.0.1" }
  return { ok: true, name: String(name).trim(), network: normalized, gateway: String(gateway).trim() }
}

function makeId() {
  return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10)
}

// Build id -> "active" | "missing" | "disabled" from the parsed route table.
// A rule is active when any main-table entry has its exact destination and
// gateway; anything else (absent, or same dst through another gateway) is
// missing, matching the macOS verifyRoute semantics.
function verifyStatuses(routes, tableEntries) {
  var entries = tableEntries instanceof Array ? tableEntries : []
  var statuses = {}
  for (var r = 0; r < routes.length; r++) {
    var rule = routes[r]
    if (!rule.enabled) {
      statuses[rule.id] = "disabled"
      continue
    }
    var key = dstKey(rule.network)
    var found = false
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (e && String(e.dst || "") === key && String(e.gateway || "") === rule.gateway) {
        found = true
        break
      }
    }
    statuses[rule.id] = found ? "active" : "missing"
  }
  return statuses
}

// Bound and copy only known fields off whatever the state file claims.
function sanitizeRoutes(raw) {
  var out = []
  if (!(raw instanceof Array)) return out
  for (var i = 0; i < raw.length && out.length < 100; i++) {
    var r = raw[i]
    if (!r || typeof r !== "object") continue
    var name = String(r.name || "").slice(0, 100)
    var network = normalizeCidr(r.network)
    var gateway = String(r.gateway || "")
    if (name === "" || !network || !isIPv4(gateway)) continue
    out.push({
      id: typeof r.id === "string" && r.id.length <= 40 ? r.id : makeId(),
      name: name,
      network: network,
      gateway: gateway,
      enabled: r.enabled !== false
    })
  }
  return out
}
