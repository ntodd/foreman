// Run against a disposable development instance with the dev sign-in link enabled.
import assert from "node:assert/strict"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { launch } from "./cdp.mjs"

const base = process.env.FOREMAN_E2E_URL || "http://localhost:4100"
const profile = mkdtempSync(join(tmpdir(), "foreman-consent-"))
const browser = await launch({ binary: process.env.BROWSER, profile, port: Number(process.env.CDP_PORT || 9334) })
const client_id = "foreman-cli"

async function form(path, fields) {
  const response = await fetch(base + path, { method: "POST", body: new URLSearchParams(fields) })
  return [response.status, await response.json()]
}

try {
  for (const decision of (process.env.DECISIONS || "approve,deny").split(",")) {
    await browser.send("Network.clearBrowserCookies")
    // Start in the browser to exercise the existing sign-in and same-site return path.
    await browser.goto(base + "/oauth/device")
    assert.equal(await browser.evaluate("location.pathname"), "/sign-in", decision + " requires browser login")
    await browser.click("a[href='/dev/sign-in/dev']")
    await browser.waitFor("location.pathname === '/oauth/device'")
    const [status, device] = await form("/oauth/device/code", { client_id, scope: "repos:list logs:read" })
    assert.equal(status, 200)
    await browser.fill("input[name=user_code]", device.user_code)
    await browser.submit("#lookup-code")
    await browser.waitFor("document.querySelector('#device-consent') !== null")
    const page = await browser.evaluate("document.querySelector('#device-consent').innerText")
    for (const expected of ["Foreman CLI", "repos:list", "logs:read", device.user_code]) assert.ok(page.includes(expected))
    await browser.click('button[value="' + decision + '"]')
    await browser.waitFor("document.querySelector('#decision-result') !== null")
    const [tokenStatus, tokens] = await form("/oauth/token", { client_id, device_code: device.device_code, grant_type: "urn:ietf:params:oauth:grant-type:device_code" })
    if (decision === "approve") {
      assert.equal(tokenStatus, 200)
      const me = await fetch(base + "/api/v1/me", { headers: { authorization: "Bearer " + tokens.access_token } })
      assert.equal(me.status, 200)
      assert.equal((await me.json()).kind, "user")
      console.log("PASS approval through browser login and consent issued a personal bearer accepted by /me")
    } else {
      assert.equal(tokenStatus, 400)
      assert.equal(tokens.error, "access_denied")
      console.log("PASS denial through browser login and consent returned access_denied")
    }
  }
} finally {
  await browser.close()
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
}
