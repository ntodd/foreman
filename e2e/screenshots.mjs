// Capture the sample control plane started by e2e/demo.exs.
import { mkdirSync, writeFileSync } from "node:fs"
import { launch } from "./cdp.mjs"

const base = process.env.FOREMAN_E2E_URL || "http://localhost:4100"
const out = process.env.OUT || "docs/images"
const binary = process.env.BROWSER || "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
const width = 1360
const height = 960
mkdirSync(out, { recursive: true })

const browser = await launch({ binary, profile: "tmp/demo/browser-profile", width, height })

async function linkTo(path, selector, name) {
  await browser.goto(base + path)
  const link = `[...document.querySelectorAll(${JSON.stringify(selector)})]
    .find(a => a.textContent.includes(${JSON.stringify(name)}))`
  await browser.waitFor(`Boolean(${link})`)
  return browser.evaluate(`${link}.getAttribute('href')`)
}

async function capture(name, path, theme, { ready, crop, through = crop, prepare }) {
  await browser.goto(base + path)
  await browser.waitFor(`document.documentElement.dataset.theme === '${theme}' &&
    document.querySelector('.phx-connected') && document.querySelector(${JSON.stringify(ready)})`)
  if (prepare) await prepare()
  await browser.evaluate("document.fonts.ready.then(() => true)")

  // Keep the navigation in the overview. Crop detail shots to the controls
  // being described so their labels are readable at GitHub's README width.
  const clip = crop && await browser.evaluate(`(() => {
    const first = document.querySelector(${JSON.stringify(crop)}).getBoundingClientRect()
    const last = document.querySelector(${JSON.stringify(through)}).getBoundingClientRect()
    const pad = 12
    return { x: first.left + scrollX - pad, y: first.top + scrollY - pad,
      width: first.width + 2 * pad, height: last.bottom - first.top + 2 * pad, scale: 1 }
  })()`)
  const { data } = await browser.send("Page.captureScreenshot", {
    format: "png", captureBeyondViewport: true, ...(clip && { clip }),
  })
  const file = `${out}/${name}-${theme}.png`
  writeFileSync(file, Buffer.from(data, "base64"))
  console.log(file)
}

try {
  await browser.goto(base + "/dev/sign-in/mona")
  await browser.waitFor("location.pathname === '/'")
  await browser.send("Emulation.setDeviceMetricsOverride", {
    width, height, deviceScaleFactor: 1.5, mobile: false,
  })

  const env = await linkTo("/", "tr[id^=env-] a", "storefront-2")
  const box = await linkTo("/boxes", "a[id^=box-]", "mona-desktop")
  const repo = await linkTo("/repos", "li[id^=repo-] a", "storefront")
  const create = await linkTo(repo, "a[href^='/environments/new']", "New environment")

  const pages = [
    ["environments", "/", { ready: "#my-environments" }],
    ["new-environment", create, {
      ready: "#new-environment", crop: "main > div",
      prepare: async () => {
        await browser.fill("#environment_branch", "checkout-redesign")
        await browser.evaluate("document.activeElement.blur()")
      },
    }],
    ["environment", env, {
      ready: "#port-3000", crop: "#connect div:has(> a[href^='vscode:'])", through: "#ports",
    }],
    ["box", box + "?range=1d", { ready: "#usage svg", crop: "#usage" }],
    ["boxes", "/boxes", { ready: "a[id^=box-]" }],
    ["secrets", "/secrets", { ready: "#user-secrets" }],
  ]

  for (const theme of ["light", "dark"]) {
    await browser.evaluate(`localStorage.setItem('phx:theme', '${theme}')`)
    for (const [name, path, options] of pages) await capture(name, path, theme, options)
  }
} finally {
  await browser.close()
}
