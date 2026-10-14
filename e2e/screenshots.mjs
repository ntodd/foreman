// README screenshots. Captures pages of the demo control plane (see
// e2e/demo.exs) in light and dark, and puts each one in a browser window.
// Writes docs/images/<page>-<theme>.png.
//
//   node e2e/screenshots.mjs
import { mkdirSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import { pathToFileURL } from "node:url"
import { launch } from "./cdp.mjs"

const base = process.env.FOREMAN_E2E_URL || "http://localhost:4100"
const out = process.env.OUT || "docs/images"
const work = "tmp/demo/shots"
const binary = process.env.BROWSER || "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
// The control plane is only reachable on the tailnet.
const host = "foreman.tail4f2c9.ts.net"
const width = 1440
const height = 900
const pad = 40
const bar = 52
// The frame is downsampled from the 2x capture; 1.5x is plenty for a README.
const outputScale = 1.5
mkdirSync(out, { recursive: true })
mkdirSync(work, { recursive: true })

const browser = await launch({ binary, profile: "tmp/demo/browser-profile", width, height })
const viewport = (w, h, scale) =>
  browser.send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: scale, mobile: false })

const envPath = async slug => {
  await browser.goto(`${base}/`)
  const expr = `[...document.querySelectorAll("[id^=env-]")].find(r => r.textContent.includes(${JSON.stringify(slug)}))?.querySelector("a[href^='/environments/']")?.getAttribute("href")`
  await browser.waitFor(`(${expr}) != null`)
  return browser.evaluate(expr)
}

const capture = async (file, path, theme) => {
  await viewport(width, height, 2)
  // The theme lives in the app origin's localStorage, so set it from there.
  await browser.goto(`${base}/`)
  await browser.evaluate(`localStorage.setItem('phx:theme', '${theme}')`)
  await browser.goto(`${base}${path}`)
  await new Promise(r => setTimeout(r, 600))
  const { data } = await browser.send("Page.captureScreenshot", { format: "png" })
  writeFileSync(file, Buffer.from(data, "base64"))
}

const chrome = {
  light: { bar: "#ececee", line: "#d4d4d8", field: "#ffffff", text: "#3f3f46", icon: "#a1a1aa" },
  dark: { bar: "#2a2a2e", line: "#141416", field: "#3a3a3f", text: "#e4e4e7", icon: "#71717a" },
}

const frameHtml = (img, theme) => {
  const c = chrome[theme]
  const chevron = d => `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="${c.icon}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="${d}"/></svg>`
  return `<!doctype html><html><head><style>
  html, body { margin: 0; background: transparent; }
  #frame { padding: ${pad}px; width: ${width}px; }
  .window { border-radius: 12px; overflow: hidden; background: ${c.bar};
    box-shadow: 0 0 0 1px rgba(0,0,0,${theme === "dark" ? 0.5 : 0.12}), 0 18px 40px rgba(0,0,0,0.22), 0 4px 12px rgba(0,0,0,0.08); }
  .bar { height: ${bar}px; display: flex; align-items: center; padding: 0 16px; gap: 18px;
    border-bottom: 1px solid ${c.line}; box-sizing: border-box; position: relative; }
  .lights { display: flex; gap: 8px; }
  .lights span { width: 12px; height: 12px; border-radius: 50%; box-shadow: inset 0 0 0 0.5px rgba(0,0,0,0.15); }
  .nav { display: flex; gap: 10px; }
  .url { position: absolute; left: 50%; transform: translateX(-50%); width: 520px; height: 30px; border-radius: 8px;
    background: ${c.field}; display: flex; align-items: center; justify-content: center; gap: 6px;
    font: 13px/1 -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", sans-serif; color: ${c.text};
    box-shadow: 0 0 0 0.5px ${c.line}; }
  img { display: block; width: ${width}px; height: ${height}px; }
  </style></head><body><div id="frame"><div class="window">
    <div class="bar">
      <div class="lights"><span style="background:#ff5f57"></span><span style="background:#febc2e"></span><span style="background:#28c840"></span></div>
      <div class="nav">${chevron("M10 3.5 5.5 8l4.5 4.5")}${chevron("M6 3.5 10.5 8 6 12.5")}</div>
      <div class="url"><svg width="11" height="12" viewBox="0 0 11 12" fill="${c.icon}"><rect x="1" y="5" width="9" height="7" rx="1.5"/><path d="M3 5V3.5a2.5 2.5 0 0 1 5 0V5" fill="none" stroke="${c.icon}" stroke-width="1.4"/></svg>${host}</div>
    </div>
    <img src="${pathToFileURL(resolve(img)).href}">
  </div></div></body></html>`
}

const frame = async (img, theme, file) => {
  const html = `${work}/frame.html`
  writeFileSync(html, frameHtml(img, theme))
  const w = width + 2 * pad
  const h = height + bar + 2 * pad
  await viewport(w, h, outputScale)
  await browser.send("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } })
  await browser.goto(pathToFileURL(resolve(html)).href)
  await browser.waitFor("document.querySelector('img').complete")
  const { data } = await browser.send("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: w, height: h, scale: 1 } })
  writeFileSync(file, Buffer.from(data, "base64"))
  await browser.send("Emulation.setDefaultBackgroundColorOverride", {})
}

try {
  await browser.goto(`${base}/dev/sign-in/nate`)
  await browser.waitFor("location.pathname === '/'")

  const pages = [
    ["environments", "/"],
    ["environment", await envPath("storefront-2")],
    ["boxes", "/boxes"],
    ["secrets", "/secrets"],
  ]

  for (const [name, path] of pages) {
    for (const theme of ["light", "dark"]) {
      const shot = `${work}/${name}-${theme}.png`
      await capture(shot, path, theme)
      await frame(shot, theme, `${out}/${name}-${theme}.png`)
      console.log(`  ${out}/${name}-${theme}.png  ${path}`)
    }
  }
} finally {
  await browser.close()
}
