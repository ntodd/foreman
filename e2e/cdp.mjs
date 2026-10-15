// A tiny Chrome DevTools Protocol driver for the end-to-end checks, so
// they need nothing but Node and a Chromium-based browser.
import { spawn } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { setTimeout as sleep } from "node:timers/promises"

export async function launch({ binary, profile, port = 9333, width = 1440, height = 900 }) {
  mkdirSync(profile, { recursive: true })
  const proc = spawn(binary, [
    "--headless=new",
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    `--window-size=${width},${height}`,
    "--no-first-run",
    "--no-default-browser-check",
    "about:blank",
  ], { stdio: "ignore" })

  let targets
  for (let i = 0; i < 50; i++) {
    try {
      targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
      if (targets.some(t => t.type === "page")) break
    } catch (_e) {}
    await sleep(200)
  }
  const page = targets.find(t => t.type === "page")
  const ws = new WebSocket(page.webSocketDebuggerUrl)
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject })

  let id = 0
  const pending = new Map()
  const listeners = []
  ws.onmessage = event => {
    const msg = JSON.parse(event.data)
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id)
      pending.delete(msg.id)
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result)
    } else if (msg.method) {
      for (const l of listeners) l(msg)
    }
  }

  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const msgId = ++id
    pending.set(msgId, { resolve, reject })
    ws.send(JSON.stringify({ id: msgId, method, params }))
  })

  await send("Page.enable")
  await send("Runtime.enable")
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false })

  const consoleErrors = []
  listeners.push(msg => {
    if (msg.method === "Runtime.exceptionThrown") consoleErrors.push(msg.params.exceptionDetails.text)
    if (msg.method === "Runtime.consoleAPICalled" && msg.params.type === "error") {
      consoleErrors.push(msg.params.args.map(a => a.value ?? a.description).join(" "))
    }
    if (msg.method === "Log.entryAdded" && msg.params.entry.level === "error") consoleErrors.push(msg.params.entry.text)
  })
  await send("Log.enable")

  const evaluate = async expression => {
    const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text)
    return r.result.value
  }

  const browser = {
    send,
    evaluate,
    consoleErrors,
    // Subscribe to DevTools events ({method, params}).
    on: listener => listeners.push(listener),
    async goto(url) {
      await send("Page.navigate", { url })
      await browser.waitFor("document.readyState === 'complete'")
      // Let LiveView connect.
      await browser.waitFor("!document.querySelector('[data-phx-main]') || document.querySelector('.phx-connected') !== null", 10000).catch(() => {})
    },
    async waitFor(expression, timeout = 15000, interval = 250) {
      const start = Date.now()
      while (Date.now() - start < timeout) {
        try { if (await evaluate(expression)) return true } catch (_e) {}
        await sleep(interval)
      }
      throw new Error(`timed out waiting for: ${expression}`)
    },
    async screenshot(path, { fullPage = true } = {}) {
      let clip
      if (fullPage) {
        const { contentSize } = await send("Page.getLayoutMetrics")
        clip = { x: 0, y: 0, width: width, height: Math.min(Math.ceil(contentSize.height), 4000), scale: 1 }
      }
      const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: fullPage, ...(clip ? { clip } : {}) })
      writeFileSync(path, Buffer.from(data, "base64"))
    },
    async click(selector) {
      await browser.waitFor(`document.querySelector(${JSON.stringify(selector)}) !== null`)
      await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`)
    },
    async clickText(selector, text) {
      const expr = `[...document.querySelectorAll(${JSON.stringify(selector)})].find(e => e.textContent.trim().includes(${JSON.stringify(text)}))`
      await browser.waitFor(`${expr} !== undefined`)
      await evaluate(`${expr}.click()`)
    },
    async fill(selector, value) {
      await browser.waitFor(`document.querySelector(${JSON.stringify(selector)}) !== null`)
      await evaluate(`(() => {
        const el = document.querySelector(${JSON.stringify(selector)});
        el.focus();
        el.value = ${JSON.stringify(value)};
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
      })()`)
    },
    async submit(selector) {
      await evaluate(`document.querySelector(${JSON.stringify(selector)}).requestSubmit()`)
    },
    async close() {
      try { await send("Browser.close") } catch (_e) {}
      proc.kill()
    },
  }
  return browser
}
