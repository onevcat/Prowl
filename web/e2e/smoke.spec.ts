import { type APIRequestContext, type Page, expect, test } from "@playwright/test";

const daemonURL = "ws://127.0.0.1:7879/ws";
const daemonHTTPURL = "http://127.0.0.1:7879";
const token = "e2e-token";

test.describe.configure({ mode: "serial" });

test("declares the PWA manifest and install icons", async ({ page, request }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator('link[rel="manifest"]')).toHaveAttribute("href", "/manifest.webmanifest");
  await expect(page.locator('meta[name="theme-color"]')).toHaveAttribute("content", "#0a84ff");

  const response = await request.get("/manifest.webmanifest");
  expect(response.ok()).toBe(true);
  const manifest = (await response.json()) as {
    name?: string;
    display?: string;
    icons?: Array<{ src?: string; sizes?: string; purpose?: string }>;
  };
  expect(manifest.name).toBe("Prowl Web");
  expect(manifest.display).toBe("standalone");
  expect(manifest.icons?.some((icon) => icon.src === "/icon-512.png" && icon.purpose?.includes("maskable"))).toBe(true);
});

test("ships the browser content security policy", async ({ page }) => {
  const response = await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  const csp = response?.headers()["content-security-policy"] ?? "";

  expect(csp).toContain("connect-src 'self' http://127.0.0.1:* http://localhost:* https:");
  expect(csp).toContain("ws://127.0.0.1:* ws://localhost:* wss:");
  expect(csp).toContain("worker-src 'self' blob:");
  await expect(page.locator(".connection.open")).toBeVisible();
});

test("logs in with a daemon token", async ({ page }) => {
  await installWebSocketURLRecorder(page);
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}`);

  await expect(page.getByRole("heading", { name: "Connect to prowld" })).toBeVisible();
  await page.getByLabel("Token").fill(token);
  await page.getByRole("button", { name: "Connect" }).click();

  await expect(page.locator(".connection.open")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Shell" })).toBeVisible();
  await expect.poll(() => page.evaluate(() => sessionStorage.getItem("prowl:token"))).toBeNull();
  await expect.poll(() => page.evaluate(() => location.href)).not.toContain("token=");
  await expect
    .poll(() =>
      page.evaluate(() =>
        ((window as unknown as { __prowlWebSocketURLs?: string[] }).__prowlWebSocketURLs ?? []).some((url) =>
          url.includes("token="),
        ),
      ),
    )
    .toBe(false);
});

test("connects to the daemon and writes through the terminal", async ({ page }) => {
  await installWebSocketURLRecorder(page);
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);

  await expect(page.locator(".connection.open")).toBeVisible();
  const terminal = page.getByRole("textbox", { name: "Shell" });
  await expect(terminal).toBeVisible();
  await expect.poll(() => page.evaluate(() => sessionStorage.getItem("prowl:token"))).toBe(token);
  await expect.poll(() => page.evaluate(() => location.href)).not.toContain("token=");
  await expect
    .poll(() =>
      page.evaluate(() =>
        ((window as unknown as { __prowlWebSocketURLs?: string[] }).__prowlWebSocketURLs ?? []).some((url) =>
          url.includes("token="),
        ),
      ),
    )
    .toBe(false);

  await terminal.click();
  await page.keyboard.type("printf e2e-smoke");
  await page.keyboard.press("Enter");

  await expect(terminal).toContainText("e2e-smoke");
});

test("re-attaches visible panes after a websocket reconnect", async ({ page, request }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Shell" })).toBeVisible();

  const before = await debugStats(request);
  await request.post(`${daemonHTTPURL}/debug/close-websockets`);

  await expect(page.locator(".connection.closed")).toBeVisible();
  await expect(page.locator(".connection.open")).toBeVisible();
  await expect
    .poll(async () => (await debugStats(request)).paneAttachRequests)
    .toBeGreaterThan(before.paneAttachRequests);
});

test("recreates visible panes that disappeared from the daemon", async ({ page, request }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Shell" })).toBeVisible();

  const before = await debugStats(request);
  const dropped = await request.post(`${daemonHTTPURL}/debug/drop-first-pane`);
  await expect(dropped).toBeOK();
  await request.post(`${daemonHTTPURL}/debug/close-websockets`);

  await expect(page.locator(".connection.closed")).toBeVisible();
  await expect(page.locator(".connection.open")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Shell" })).toBeVisible();
  await expect
    .poll(async () => (await debugStats(request)).paneCreateRequests)
    .toBeGreaterThan(before.paneCreateRequests);
  await expect(page.locator(".error")).toHaveCount(0);
});

test("broadcasts canvas input to every visible pane", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "New Tab (Command T)" }).click();
  await page.getByRole("button", { name: "Show Canvas" }).click();

  const terminals = page.getByRole("textbox", { name: "Shell" });
  await expect(terminals).toHaveCount(2);

  await page.getByLabel("Broadcast input").fill("printf canvas-broadcast");
  await page.keyboard.press("Enter");

  await expect(terminals.nth(0)).toContainText("canvas-broadcast");
  await expect(terminals.nth(1)).toContainText("canvas-broadcast");
});

test("runs custom actions from the shelf toolbar", async ({ page }) => {
  const suffix = crypto.randomUUID().slice(0, 8);
  const actionName = `Toolbar ${suffix}`;
  const output = `toolbar-action-${suffix}`;
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings" }).click();
  await page.getByLabel("Action name").fill(actionName);
  await page.getByLabel("Action command").fill(`printf ${output}`);
  await page.getByRole("button", { name: "Add Custom Action" }).click();
  await expect(page.getByRole("heading", { name: actionName })).toBeVisible();

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  await page.getByRole("button", { name: "Run Custom Action" }).click();
  await page.getByRole("menuitem", { name: new RegExp(actionName) }).click();

  await expect(page.getByRole("textbox", { name: "Shell" })).toContainText(output);
});

async function debugStats(request: APIRequestContext): Promise<{
  paneAttachRequests: number;
  paneCreateRequests: number;
}> {
  const response = await request.get(`${daemonHTTPURL}/debug/stats`);
  return (await response.json()) as { paneAttachRequests: number; paneCreateRequests: number };
}

async function installWebSocketURLRecorder(page: Page): Promise<void> {
  await page.addInitScript(() => {
    const socketURLs: string[] = [];
    const trackedWebSocket = new Proxy(window.WebSocket, {
      construct(target, args) {
        socketURLs.push(String(args[0]));
        return Reflect.construct(target, args);
      },
    });

    Object.defineProperty(window, "__prowlWebSocketURLs", {
      value: socketURLs,
    });
    window.WebSocket = trackedWebSocket;
  });
}
