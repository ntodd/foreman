// End-to-end run through the UI against a dev control plane with a local
// agent (see e2e/README.md): sign in, create an environment, wait for it
// to run, change a secret and restart affected services, then destroy it.
// Screenshots go to tmp/e2e/shots.
import { mkdirSync } from "node:fs"
import { launch } from "./cdp.mjs"

const base = process.env.FOREMAN_E2E_URL || "http://localhost:4100"
const shots = process.env.SHOTS || "tmp/e2e/shots"
const binary = process.env.BROWSER || "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
const only = process.env.ONLY // "pages" just screenshots every page
mkdirSync(shots, { recursive: true })

const browser = await launch({ binary, profile: "tmp/e2e/browser-profile", height: 1100 })
const shot = async name => {
  await new Promise(r => setTimeout(r, 400))
  await browser.screenshot(`${shots}/${name}.png`, { fullPage: false })
  console.log(`  screenshot ${name}`)
}
const step = name => console.log(`- ${name}`)

try {
  step("sign in (dev)")
  await browser.goto(`${base}/dev/sign-in/dev`)
  await browser.waitFor("location.pathname === '/'")
  await shot("01-home")

  if (only !== "pages") {
    step("create an environment")
    await browser.goto(`${base}/environments/new`)
    await shot("02-new")
    await browser.submit("#new-environment")
    await browser.waitFor("location.pathname.startsWith('/environments/') && location.pathname !== '/environments/new'", 15000)
    const envPath = await browser.evaluate("location.pathname")
    console.log(`  ${envPath}`)
    await shot("03-creating")

    step("wait for it to run (first build pulls images)")
    await browser.waitFor("document.querySelector('[data-state=running]') !== null", 15 * 60 * 1000, 2000)
    await shot("04-running")

    step("add an environment secret")
    await browser.fill("#env-secrets-form input[name='secret[name]']", "SIDECAR_TOKEN")
    await browser.fill("#env-secrets-form textarea[name='secret[value]']", "from-the-ui")
    await browser.submit("#env-secrets-form")
    await browser.waitFor("document.querySelector('#pending-restart') !== null", 20000)
    await shot("05-pending-restart")

    step("restart affected")
    await browser.clickText("#pending-restart button", "Restart affected")
    await browser.waitFor("document.querySelector('#pending-restart') === null && document.querySelector('[data-state=running]') !== null", 5 * 60 * 1000, 1000)
    await shot("06-restarted")

    step("container logs")
    await browser.clickText("button", "Container logs")
    await browser.waitFor("document.querySelector('#op-log').textContent.includes('sidecar')", 60000, 1000)
    await shot("07-logs")
  }

  step("tour the other pages")
  for (const [name, path] of [["10-boxes", "/boxes"], ["11-repos", "/repos"], ["12-secrets", "/secrets"], ["13-settings", "/settings"], ["14-admin", "/admin"], ["15-people", "/admin/users"], ["16-audit", "/admin/audit"]]) {
    await browser.goto(`${base}${path}`)
    await shot(name)
  }
  await browser.goto(`${base}/boxes`)
  await browser.click("[id^=box-] ")
  await browser.waitFor("location.pathname.startsWith('/boxes/')")
  await shot("17-box")
  await browser.goto(`${base}/repos`)
  await browser.click("[id^=repo-] a")
  await browser.waitFor("location.pathname.startsWith('/repos/')")
  await shot("18-repo")

  step("dark theme")
  await browser.evaluate("localStorage.setItem('phx:theme', 'dark')")
  await browser.goto(`${base}/`)
  await shot("20-home-dark")

  if (only !== "pages") {
    step("destroy")
    await browser.evaluate("localStorage.setItem('phx:theme', 'light')")
    await browser.goto(`${base}/`)
    await browser.click("[id^=env-] a")
    await browser.waitFor("document.querySelector('[data-state]') !== null")
    await browser.click("#env-actions-trigger")
    await browser.clickText("#env-actions [role=menuitem]", "Destroy")
    await browser.waitFor("document.querySelector('#destroy-modal') && !document.querySelector('#destroy-modal').textContent.includes('Checking for unsaved work')", 120000, 1000)
    await shot("08-destroy-check")
    const needsConfirm = await browser.evaluate("document.querySelector('#destroy-modal input[name=confirm]') !== null")
    if (needsConfirm) {
      const slug = await browser.evaluate("document.querySelector('#destroy-modal-title').textContent.replace('Destroy ', '').replace('?', '').trim()")
      await browser.fill("#destroy-modal input[name=confirm]", slug)
    }
    await browser.clickText("#destroy-modal button", "Destroy")
    await browser.waitFor("location.pathname === '/'", 15000)
    await shot("09-destroying")
  }

  if (browser.consoleErrors.length) {
    console.log("browser console errors:")
    for (const e of browser.consoleErrors) console.log(`  ${e}`)
    process.exitCode = 1
  } else {
    console.log("no browser console errors")
  }
} catch (error) {
  console.error(error)
  await browser.screenshot(`${shots}/failure.png`).catch(() => {})
  process.exitCode = 1
} finally {
  await browser.close()
}
