// Layout checks against the demo control plane (see e2e/demo.exs): every
// page at phone, tablet, laptop and desktop widths, in a headless browser.
// A page fails if it scrolls sideways or squeezes text it shows down to
// nothing (a table whose fixed columns leave none for the name, say).
// Exits non-zero on a failure.
//
//   cd apps/foreman && PORT=4100 mix run --no-start ../../e2e/demo.exs &
//   node e2e/layout.mjs
import { launch } from "./cdp.mjs"

const base = process.env.FOREMAN_E2E_URL || "http://localhost:4100"
const binary = process.env.BROWSER || "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
const widths = [390, 768, 1024, 1440]

const browser = await launch({ binary, profile: "tmp/demo/layout-profile" })
const failures = []

// The first link in a list row or card whose text matches.
const hrefOf = async (path, selector, text) => {
  await browser.goto(`${base}${path}`)
  const expr = `[...document.querySelectorAll(${JSON.stringify(selector)})].find(a => a.textContent.includes(${JSON.stringify(text)}))?.getAttribute("href")`
  await browser.waitFor(`(${expr}) != null`)
  return browser.evaluate(expr)
}

// Text the page shows but has no room for: an element that is displayed,
// has text of its own, and gets less than 16px of the width it needs.
const squeezed = `(() => {
  const out = []
  for (const el of document.querySelectorAll("main *, #main *")) {
    const own = [...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim() !== "")
    if (!own || el.closest(".sr-only, [hidden], template, svg")) continue
    const style = getComputedStyle(el)
    if (style.display === "none" || style.visibility === "hidden" || el.getClientRects().length === 0) continue
    const width = el.getBoundingClientRect().width
    if (width < Math.min(el.scrollWidth, 16)) out.push(el.tagName.toLowerCase() + ": " + el.textContent.trim().slice(0, 40))
  }
  return out.slice(0, 5)
})()`

try {
  await browser.goto(`${base}/dev/sign-in/mona`)
  await browser.waitFor("location.pathname === '/'")

  const pages = [
    ["environments", "/"],
    ["environment", await hrefOf("/", "tr[id^=env-] a[href^='/environments/']", "storefront-2")],
    ["new environment", "/environments/new"],
    ["repos", "/repos"],
    ["repo", await hrefOf("/repos", "a[href^='/repos/']", "storefront")],
    ["boxes", "/boxes"],
    ["box", await hrefOf("/boxes", "a[id^=box-]", "desktop")],
    ["secrets", "/secrets"],
    ["settings", "/settings"],
    ["deployment", "/admin"],
    ["people", "/admin/users"],
    ["audit log", "/admin/audit"],
  ]

  for (const width of widths) {
    await browser.send("Emulation.setDeviceMetricsOverride", { width, height: 900, deviceScaleFactor: 1, mobile: width < 768 })

    for (const [name, path] of pages) {
      await browser.goto(`${base}${path}`)
      await new Promise(r => setTimeout(r, 300))
      const problems = []

      const { scroll, client } = await browser.evaluate(
        "({scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth})"
      )
      if (scroll > client) problems.push(`scrolls sideways (${scroll}px of content in ${client}px)`)

      for (const text of await browser.evaluate(squeezed)) problems.push(`no room for ${text}`)

      const status = problems.length ? "FAIL" : "ok"
      console.log(`${status.padEnd(4)} ${String(width).padStart(4)}px  ${name}`)
      for (const p of problems) {
        console.log(`       ${p}`)
        failures.push(`${width}px ${name}: ${p}`)
      }
    }
  }
} finally {
  await browser.close()
}

if (failures.length) {
  console.log(`\n${failures.length} layout problem(s)`)
  process.exit(1)
}
