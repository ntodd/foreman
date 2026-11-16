// Clicks a phx-click on a LiveView page, as a signed-in user, without a
// browser: what an end-to-end run does to press a button whose work
// happens in the running control plane (a box command, say), which an
// eval in a separate VM can't reach.
//
//   node e2e/lv-click.mjs <base-url> <cookie> <path> <event> [value-json]
//
// The cookie is a session cookie (name=value), from E2E.session_cookie().
// Prints the reply's flash, and exits non-zero if the join or the event
// fails.
const [base, cookie, path, event, valueJson = "{}"] = process.argv.slice(2)
if (!event) {
  console.error("usage: lv-click.mjs <base-url> <cookie> <path> <event> [value-json]")
  process.exit(64)
}

const page = await fetch(new URL(path, base), { headers: { cookie } })
if (!page.ok) throw new Error(`GET ${path}: ${page.status}`)
const html = await page.text()
// The page put a CSRF token in the session; the socket checks the one it
// sends against it, so it needs the session as the page left it.
const name = cookie.split("=")[0]
const updated = page.headers.getSetCookie().find(c => c.startsWith(`${name}=`))
const sessionCookie = updated ? updated.split(";")[0] : cookie
const attr = (name, scope = html) => {
  const m = scope.match(new RegExp(`${name}="([^"]*)"`))
  if (!m) throw new Error(`no ${name} on ${path}`)
  return m[1].replaceAll("&amp;", "&").replaceAll("&quot;", '"')
}
const csrf = attr('<meta name="csrf-token" content')
const main = html.match(/<div[^>]*data-phx-main[^>]*>/)?.[0]
if (!main) throw new Error(`${path} has no LiveView`)
const id = attr("id", main)
const session = attr("data-phx-session", main)
const staticToken = attr("data-phx-static", main)

const wsUrl = new URL("/live/websocket", base)
wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:"
wsUrl.search = new URLSearchParams({ _csrf_token: csrf, vsn: "2.0.0" })
const ws = new WebSocket(wsUrl, { headers: { cookie: sessionCookie, origin: base } })

let ref = 0
const replies = new Map()
const send = (topic, ev, payload) => {
  const r = String(++ref)
  ws.send(JSON.stringify(["1", r, topic, ev, payload]))
  return new Promise((resolve, reject) => {
    replies.set(r, { resolve, reject })
    setTimeout(() => reject(new Error(`no reply to ${ev}`)), 15000)
  })
}
ws.onmessage = msg => {
  const [, r, , ev, payload] = JSON.parse(msg.data)
  if (ev === "phx_reply" && replies.has(r)) {
    const { resolve, reject } = replies.get(r)
    replies.delete(r)
    payload.status === "ok" ? resolve(payload.response) : reject(new Error(JSON.stringify(payload)))
  }
}
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject })

const topic = `lv:${id}`
await send(topic, "phx_join", {
  url: new URL(path, base).toString(),
  params: { _csrf_token: csrf, _mounts: 0 },
  session,
  static: staticToken,
})
const reply = await send(topic, "event", { type: "click", event, value: JSON.parse(valueJson) })

// The flash, if the event set one, wherever the diff carries it.
const flash = JSON.stringify(reply).match(/(Sent to [^"<]*|Rebooting [^"<]*|[^">]*can't[^"<]*|Only admins[^"<]*)/)
console.log(flash ? flash[1] : "ok")
if (process.env.LV_CLICK_DEBUG) console.error(JSON.stringify(reply).slice(0, 2000))
ws.close()
