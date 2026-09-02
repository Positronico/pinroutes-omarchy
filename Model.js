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

function ipToInt(str) {
  var m = String(str || "").match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
  if (!m) return -1
  return ((parseInt(m[1], 10) * 16777216) + (parseInt(m[2], 10) * 65536)
        + (parseInt(m[3], 10) * 256) + parseInt(m[4], 10)) >>> 0
}

// Does a route-table dst ("default", "10.9.9.9", "10.255.10.0/24") cover ip?
function dstContains(dst, ip) {
  var cidr = String(dst || "")
  if (cidr === "default") cidr = "0.0.0.0/0"
  if (cidr.indexOf("/") === -1) cidr = cidr + "/32"
  var parsed = parseCidr(cidr)
  var addr = ipToInt(ip)
  if (!parsed || addr < 0) return false
  var base = ((parsed.octets[0] * 16777216) + (parsed.octets[1] * 65536)
            + (parsed.octets[2] * 256) + parsed.octets[3]) >>> 0
  var mask = parsed.prefix === 0 ? 0 : (0xFFFFFFFF << (32 - parsed.prefix)) >>> 0
  return ((addr & mask) >>> 0) === ((base & mask) >>> 0)
}

// Mirrors the kernel's nexthop validation: `ip route replace X via GW` only
// succeeds when GW resolves through a directly-connected route — an entry
// with no gateway of its own (link-scope subnet, host route, or a dev-only
// default as point-to-point VPNs install). When this is false the gateway is
// off-net (wifi still reassociating, foreign network, VPN tunnel down) and
// applying would fail with "Nexthop has invalid gateway".
function isGatewayOnLink(gateway, tableEntries) {
  var entries = tableEntries instanceof Array ? tableEntries : []
  if (!isIPv4(gateway)) return false
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    if (!e || typeof e.dst !== "string") continue
    if (e.gateway !== undefined && e.gateway !== null && String(e.gateway) !== "") continue
    if (dstContains(e.dst, gateway)) return true
  }
  return false
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

// Build id -> "active" | "missing" | "standby" | "disabled" from the parsed
// route table. A rule is active when any main-table entry has its exact
// destination and gateway. When the rule's gateway is not on-link the rule is
// in standby: applying is impossible on this network (the kernel would refuse
// the nexthop), so it is neither a problem to alert on nor a route to fix —
// the netlink monitor flips it back the moment the gateway's subnet returns.
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
    if (found) statuses[rule.id] = "active"
    else statuses[rule.id] = isGatewayOnLink(rule.gateway, entries) ? "missing" : "standby"
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
