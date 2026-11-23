// Run against a disposable development instance with the dev sign-in link enabled.
import assert from "node:assert/strict"
import { execFile, spawn } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { createHash } from "node:crypto"
import { createInterface } from "node:readline"
import { promisify } from "node:util"
import { once } from "node:events"
import { fileURLToPath } from "node:url"
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
    const exchange = () => form("/oauth/token", { client_id, device_code: device.device_code, grant_type: "urn:ietf:params:oauth:grant-type:device_code" })
    if (decision === "approve") {
      const [success, replay] = (await Promise.all([exchange(), exchange()])).sort(([a], [b]) => a - b)
      assert.equal(success[0], 200)
      assert.equal(replay[1].error, "invalid_grant")
      const tokens = success[1]
      const me = await fetch(base + "/api/v1/me", { headers: { authorization: "Bearer " + tokens.access_token } })
      assert.equal(me.status, 200)
      assert.equal((await me.json()).kind, "user")
      console.log("PASS approval through browser login and consent issued a personal bearer accepted by /me")
    } else {
      const [tokenStatus, tokens] = await exchange()
      assert.equal(tokenStatus, 400)
      assert.equal(tokens.error, "access_denied")
      console.log("PASS denial through browser login and consent returned access_denied")
    }
  }
  const state = mkdtempSync(join(tmpdir(), "foreman-cli-"))
  try {
    const cli = fileURLToPath(new URL("../bin/foreman", import.meta.url))
    const args = ["--instance", base]
    const env = { ...process.env, XDG_STATE_HOME: state }
    const login = spawn(cli, [...args, "login", "--scope", "repos:list"], { env, stdio: ["ignore", "pipe", "inherit"] })
    const finished = once(login, "exit")
    const lines = createInterface({ input: login.stdout })
    try {
      const [prompt] = await once(lines, "line")
      const [, url, code] = /^Open (.+) and enter ([A-Z2-9-]+)$/.exec(prompt)
      await browser.goto(url)
      await browser.fill("input[name=user_code]", code)
      await browser.submit("#lookup-code")
      await browser.click('button[value="approve"]')
      assert.equal((await finished)[0], 0)
    } finally {
      if (login.exitCode === null) login.kill()
      lines.close()
    }
    const run = promisify(execFile)
    const me = async () => JSON.parse((await run(cli, [...args, "me"], { env })).stdout)
    const account = (await me()).id
    const hash = value => createHash("sha256").update(value).digest("hex")
    const saved = join(state, "foreman", hash(base), hash(account) + ".json")
    assert.equal(statSync(saved).mode & 0o777, 0o600)
    const first = JSON.parse(readFileSync(saved))
    // Move the CLI's refresh deadline forward without changing the server clock.
    writeFileSync(saved, JSON.stringify({ ...first, expires: 0 }))
    const concurrent = await Promise.all([me(), me()])
    assert.ok(concurrent.every(identity => identity.id === account))
    const rotated = JSON.parse(readFileSync(saved))
    assert.ok(rotated.refresh_token !== first.refresh_token)
    await run(cli, [...args, "--account", account, "logout"], { env })
    const afterLogout = await fetch(base + "/api/v1/me", { headers: { authorization: "Bearer " + rotated.access_token } })
    assert.equal(afterLogout.status, 401)
    console.log("PASS separate CLI processes restored private credentials, serialized refresh and revoked the connection on logout")
  } finally {
    rmSync(state, { recursive: true, force: true })
  }
} finally {
  await browser.close()
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 })
}
