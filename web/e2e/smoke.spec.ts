import { readFileSync } from "node:fs";
import { type APIRequestContext, type Browser, type CDPSession, type Page, expect, test } from "@playwright/test";

const daemonURL = "ws://127.0.0.1:7879/ws";
const daemonHTTPURL = "http://127.0.0.1:7879";
const token = "e2e-token";
const daemonRssBudgetBytes = 120 * 1024 * 1024;
const clientRendererRssBudgetBytes = 350 * 1024 * 1024;

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

test("ships a service worker for PWA bundle updates", async ({ request }) => {
  const response = await request.get("/service-worker.js");
  expect(response.ok()).toBe(true);
  const worker = await response.text();
  expect(worker).toContain("prowl-web-");
  expect(worker).toContain("install");
  expect(worker).toContain("activate");
  expect(worker).toContain("fetch");
});

test("ships the browser content security policy", async ({ page }) => {
  const response = await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  const csp = response?.headers()["content-security-policy"] ?? "";

  expect(csp).toContain("connect-src 'self' http://127.0.0.1:* http://localhost:* https:");
  expect(csp).toContain("ws://127.0.0.1:* ws://localhost:* wss:");
  expect(csp).toContain("worker-src 'self' blob:");
  await expect(page.locator(".connection.open")).toBeVisible();
});

test("cold starts to the first interactive pane within budget", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Shell" })).toBeVisible();
  await expect.poll(() => coldStartDurationsMs(page).then((durations) => durations.length)).toBeGreaterThanOrEqual(1);

  const durations = await coldStartDurationsMs(page);
  expect(durations.at(-1)).toBeLessThanOrEqual(1_500);
});

test("keeps daemon RSS under budget with ten idle panes", async ({ page, request }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  const before = await debugStats(request);
  let createdPaneIds: string[] = [];
  try {
    createdPaneIds = await createIdlePanesThroughBrowser(page, before.paneCount, 10);

    await expect.poll(() => debugStats(request).then((stats) => stats.paneCount)).toBeGreaterThanOrEqual(10);
    const stats = await debugStats(request);
    expect(stats.rssBytes).toBeLessThanOrEqual(daemonRssBudgetBytes);
  } finally {
    await closePanesThroughBrowser(page, createdPaneIds);
    await expect.poll(() => debugStats(request).then((stats) => stats.paneCount)).toBe(before.paneCount);
  }
});

test("keeps Chrome renderer RSS under budget with ten idle panes", async ({ browser, page, request }) => {
  test.setTimeout(30_000);
  test.skip(process.platform !== "linux", "Chromium renderer RSS is read from /proc on Linux.");

  const before = await debugStats(request);
  let createdPaneIds: string[] = [];
  try {
    await page.goto("/manifest.webmanifest");
    createdPaneIds = await createIdlePanesThroughBrowser(page, before.paneCount, 10);

    await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
    await expect(page.locator(".connection.open")).toBeVisible();
    await expect(page.locator(".tabs > button")).toHaveCount(10);
    await page.getByRole("button", { name: "Show Canvas" }).click();

    await expect(page.locator(".grid > div")).toHaveCount(10);
    await expect(page.getByRole("textbox", { name: "Shell" })).toHaveCount(8);
    await expect(page.locator("section.renderer-idle")).toHaveCount(2);

    const rendererRssBytes = await chromeRendererRssBytes(browser);
    expect(rendererRssBytes).toBeLessThanOrEqual(clientRendererRssBudgetBytes);
  } finally {
    await closePanesThroughBrowser(page, createdPaneIds);
    await expect.poll(() => debugStats(request).then((stats) => stats.paneCount)).toBe(before.paneCount);
  }
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

test("persists appearance settings through the daemon", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("Theme").selectOption("dark");
  await page.getByLabel("Terminal density").selectOption("compact");
  await page.getByLabel("Show unread badges").uncheck();
  await page.getByRole("button", { name: "Save Appearance Settings" }).click();

  await expect.poll(() => htmlDataset(page, "theme")).toBe("dark");
  await expect.poll(() => htmlDataset(page, "terminalDensity")).toBe("compact");
  await expect.poll(() => htmlDataset(page, "unreadBadges")).toBe("false");

  await page.reload();
  await expect(page.getByRole("heading", { name: "Settings" })).toBeVisible();
  await expect(page.getByLabel("Theme")).toHaveValue("dark");
  await expect(page.getByLabel("Terminal density")).toHaveValue("compact");
  await expect(page.getByLabel("Show unread badges")).not.toBeChecked();

  await page.getByLabel("Theme").selectOption("system");
  await page.getByLabel("Terminal density").selectOption("comfortable");
  await page.getByLabel("Show unread badges").check();
  await page.getByRole("button", { name: "Save Appearance Settings" }).click();
  await page.getByRole("button", { name: "Back to Shelf" }).click();
});

test("persists shortcut settings through the daemon", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("Open palette shortcut").fill("Mod+Shift+K");
  await page.getByRole("button", { name: "Save Shortcut Settings" }).click();

  await page.reload();
  await expect(page.getByRole("heading", { name: "Settings" })).toBeVisible();
  await expect(page.getByLabel("Open palette shortcut")).toHaveValue("Mod+Shift+K");

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  await page.keyboard.press("Control+Shift+K");
  await expect(page.getByRole("textbox", { name: "Command Palette" })).toBeVisible();

  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("Open palette shortcut").fill("Mod+K");
  await page.getByRole("button", { name: "Save Shortcut Settings" }).click();
  await page.getByRole("button", { name: "Back to Shelf" }).click();
});

test("keeps terminal input p99 latency under the regression gate", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();
  const terminal = page.getByRole("textbox", { name: "Shell" });
  await expect(terminal).toBeVisible();
  await page.evaluate(() => performance.clearMeasures("prowl.input.latency"));

  await terminal.click();
  const input = "x".repeat(100);
  await page.keyboard.type(input, { delay: 20 });

  await expect.poll(() => echoedCharacterCount(terminal, "x")).toBeGreaterThanOrEqual(100);
  await expect
    .poll(() => inputLatencyDurations(page).then((durations) => durations.length))
    .toBeGreaterThanOrEqual(100);

  const durations = await inputLatencyDurations(page);
  expect(percentile(durations, 99)).toBeLessThanOrEqual(20);
});

test("keeps warm navigation interactions under budget", async ({ page }) => {
  const suffix = crypto.randomUUID().slice(0, 8);
  const worktreeName = `perf-worktree-${suffix}`;
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("e2e-repo branch").fill(`perf-${suffix}`);
  await page.getByLabel("e2e-repo worktree directory").fill(worktreeName);
  await page.getByRole("button", { name: "Create Worktree for e2e-repo" }).click();
  await expect(page.getByText(worktreeName, { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Back to Shelf" }).click();

  await page.evaluate(() => {
    performance.clearMeasures("prowl.palette.open");
    performance.clearMeasures("prowl.worktree.switch");
  });

  await page.getByRole("button", { name: "Open Command Palette" }).click();
  await expect(page.getByRole("textbox", { name: "Command Palette" })).toBeVisible();
  await expect.poll(() => paletteOpenDurationsMs(page).then((durations) => durations.length)).toBeGreaterThanOrEqual(1);
  expect((await paletteOpenDurationsMs(page)).at(-1)).toBeLessThanOrEqual(100);
  await page.keyboard.press("Escape");

  const sidebar = page.getByLabel("Worktrees and tabs");
  await sidebar.getByRole("button", { name: worktreeName }).click();
  await expect(page.getByRole("heading", { name: worktreeName })).toBeVisible();
  await expect
    .poll(() => worktreeSwitchDurationsMs(page).then((durations) => durations.length))
    .toBeGreaterThanOrEqual(1);
  expect((await worktreeSwitchDurationsMs(page)).at(-1)).toBeLessThanOrEqual(50);
});

test("opens a worktree diff from the shelf context menu", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "default" }).click({ button: "right" });
  await expect(page.getByRole("menu", { name: "Worktree Actions" })).toBeVisible();
  await page.getByRole("menuitem", { name: "Show Diff" }).click();

  await expect(page.getByRole("heading", { name: "default" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Toggle Unified or Side-by-side Diff" })).toBeVisible();
  await expect(
    page.getByRole("complementary", { name: "Changed files" }).getByRole("button", { name: /README.md/ }),
  ).toBeVisible();
  const unifiedDiff = page.getByLabel("Unified diff", { exact: true });
  await expect(unifiedDiff).toContainText("-e2e baseline");
  await expect(unifiedDiff).toContainText("+e2e changed");

  await page.getByRole("button", { name: "Toggle Unified or Side-by-side Diff" }).click();
  const splitDiff = page.getByLabel("Side-by-side diff", { exact: true });
  await expect(splitDiff).toContainText("-e2e baseline");
  await expect(splitDiff).toContainText("+e2e changed");
});

test("re-attaches visible panes after a websocket reconnect", async ({ page, request }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Shell" })).toBeVisible();
  await page.evaluate(() => performance.clearMeasures("prowl.ws.reconnect"));

  const before = await debugStats(request);
  await request.post(`${daemonHTTPURL}/debug/close-websockets`);

  await expect(page.locator(".connection.closed")).toBeVisible();
  await expect(page.locator(".connection.open")).toBeVisible();
  await expect
    .poll(async () => (await debugStats(request)).paneAttachRequests)
    .toBeGreaterThan(before.paneAttachRequests);
  const reconnectDurations = await reconnectDurationsMs(page);
  expect(reconnectDurations.at(-1)).toBeLessThanOrEqual(500);
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

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("Action name").fill(actionName);
  await page.getByLabel("Action command").fill(`printf ${output}`);
  await page.getByRole("button", { name: "Add Custom Action" }).click();
  await expect(page.getByRole("heading", { name: actionName })).toBeVisible();

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  await page.getByRole("button", { name: "Run Custom Action" }).click();
  await page.getByRole("menuitem", { name: new RegExp(actionName) }).click();

  await expect(page.getByRole("textbox", { name: "Shell" })).toContainText(output);
});

test("runs custom actions in a new pane from the shelf toolbar", async ({ page }) => {
  const suffix = crypto.randomUUID().slice(0, 8);
  const actionName = `New Pane ${suffix}`;
  const output = `new-pane-action-${suffix}`;
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("Action name").fill(actionName);
  await page.getByLabel("Action command").fill(`printf ${output}`);
  await page.getByLabel("Action output").selectOption("newPane");
  await page.getByRole("button", { name: "Add Custom Action" }).click();
  await expect(page.getByRole("heading", { name: actionName })).toBeVisible();

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  await page.getByRole("button", { name: "Run Custom Action" }).click();
  await page.getByRole("menuitem", { name: new RegExp(actionName) }).click();

  await expect(page.getByRole("textbox", { name: actionName })).toContainText(output);
});

test("runs custom actions from the command palette", async ({ page }) => {
  const suffix = crypto.randomUUID().slice(0, 8);
  const actionName = `Palette ${suffix}`;
  const output = `palette-action-${suffix}`;
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("Action name").fill(actionName);
  await page.getByLabel("Action command").fill(`printf ${output}`);
  await page.getByRole("button", { name: "Add Custom Action" }).click();
  await expect(page.getByRole("heading", { name: actionName })).toBeVisible();

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  await page.getByRole("button", { name: "Open Command Palette" }).click();
  const palette = page.getByRole("textbox", { name: "Command Palette" });
  await expect(palette).toBeVisible();
  await palette.fill(actionName);
  await page.keyboard.press("Enter");

  await expect(page.getByRole("textbox", { name: "Shell" })).toContainText(output);
});

test("runs custom actions from a shortcut", async ({ page }) => {
  const suffix = crypto.randomUUID().slice(0, 8);
  const actionName = `Shortcut ${suffix}`;
  const output = `shortcut-action-${suffix}`;
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("Action name").fill(actionName);
  await page.getByLabel("Action command").fill(`printf ${output}`);
  await page.getByLabel("Action shortcut").fill("Mod+Alt+R");
  await page.getByRole("button", { name: "Add Custom Action" }).click();
  await expect(page.getByRole("heading", { name: actionName })).toBeVisible();

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  await page.getByRole("button", { name: "Run Custom Action" }).focus();
  await page.keyboard.press("Control+Alt+R");

  await expect(page.getByRole("textbox", { name: "Shell" })).toContainText(output);
});

test("cycles worktrees through native shortcut aliases", async ({ page }) => {
  const suffix = crypto.randomUUID().slice(0, 8);
  const worktreeName = `shortcut-worktree-${suffix}`;
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("e2e-repo branch").fill(`shortcut-${suffix}`);
  await page.getByLabel("e2e-repo worktree directory").fill(worktreeName);
  await page.getByRole("button", { name: "Create Worktree for e2e-repo" }).click();
  await expect(page.getByText(worktreeName, { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  await page.getByRole("button", { name: "default", exact: true }).click();
  await expect(page.getByRole("heading", { name: "default" })).toBeVisible();
  await page.getByRole("button", { name: "Open Settings", exact: true }).focus();
  await page.keyboard.press("Control+Alt+ArrowLeft");
  await expect(page.getByRole("heading", { name: worktreeName })).toBeVisible();
  await page.keyboard.press("Control+Alt+ArrowRight");
  await expect(page.getByRole("heading", { name: "default" })).toBeVisible();
});

test("reorders worktrees and tabs with drag and drop", async ({ page }) => {
  const suffix = crypto.randomUUID().slice(0, 8);
  const worktreeName = `dnd-worktree-${suffix}`;
  const actionName = `Drag Tab ${suffix}`;
  const output = `drag-tab-${suffix}`;
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);
  await expect(page.locator(".connection.open")).toBeVisible();

  await page.getByRole("button", { name: "Open Settings", exact: true }).click();
  await page.getByLabel("e2e-repo branch").fill(`dnd-${suffix}`);
  await page.getByLabel("e2e-repo worktree directory").fill(worktreeName);
  await page.getByRole("button", { name: "Create Worktree for e2e-repo" }).click();
  await expect(page.getByText(worktreeName, { exact: true })).toBeVisible();

  await page.getByLabel("Action name").fill(actionName);
  await page.getByLabel("Action command").fill(`printf ${output}`);
  await page.getByLabel("Action output").selectOption("newPane");
  await page.getByRole("button", { name: "Add Custom Action" }).click();
  await expect(page.getByRole("heading", { name: actionName })).toBeVisible();

  await page.getByRole("button", { name: "Back to Shelf" }).click();
  const sidebar = page.getByLabel("Worktrees and tabs");
  const defaultWorktree = sidebar.getByRole("button", { name: "default" });
  const createdWorktree = sidebar.getByRole("button", { name: worktreeName });
  await expect(defaultWorktree).toBeVisible();
  await expect(createdWorktree).toBeVisible();
  await expect.poll(() => worktreeOrder(page, "default", worktreeName)).toBeLessThan(0);

  await createdWorktree.dragTo(defaultWorktree);
  await expect.poll(() => worktreeOrder(page, worktreeName, "default")).toBeLessThan(0);

  await defaultWorktree.click();
  await page.getByRole("button", { name: "Run Custom Action" }).click();
  await page.getByRole("menuitem", { name: new RegExp(actionName) }).click();
  await expect(page.getByRole("textbox", { name: actionName })).toContainText(output);

  const tabs = page.locator(".tabs > button");
  const actionTab = page.locator(".tabs").getByRole("button", { name: actionName });
  await expect(actionTab).toBeVisible();
  await expect(tabTitles(page)).resolves.toContain(`Select ${actionName}`);

  await actionTab.dragTo(tabs.first());
  await expect.poll(async () => (await tabTitles(page))[0]).toBe(`Select ${actionName}`);
});

async function debugStats(request: APIRequestContext): Promise<{
  paneAttachRequests: number;
  paneCreateRequests: number;
  paneCount: number;
  rssBytes: number;
}> {
  const response = await request.get(`${daemonHTTPURL}/debug/stats`);
  return (await response.json()) as {
    paneAttachRequests: number;
    paneCreateRequests: number;
    paneCount: number;
    rssBytes: number;
  };
}

async function chromeRendererRssBytes(browser: Browser): Promise<number> {
  type ChromiumBrowserWithCDP = Browser & { newBrowserCDPSession(): Promise<CDPSession> };
  type ProcessInfoResponse = {
    processInfo: Array<{
      type: string;
      id: number;
    }>;
  };

  const session = await (browser as ChromiumBrowserWithCDP).newBrowserCDPSession();
  const { processInfo } = (await session.send("SystemInfo.getProcessInfo")) as ProcessInfoResponse;
  return processInfo
    .filter((process) => process.type === "renderer")
    .reduce((total, process) => total + processRssBytes(process.id), 0);
}

function processRssBytes(pid: number): number {
  const status = readFileSync(`/proc/${pid}/status`, "utf8");
  const match = /^VmRSS:\s+(\d+)\s+kB$/m.exec(status);
  if (!match) {
    throw new Error(`Could not read RSS for process ${pid}`);
  }
  return Number(match[1]) * 1024;
}

async function createIdlePanesThroughBrowser(
  page: Page,
  currentPaneCount: number,
  targetPaneCount: number,
): Promise<string[]> {
  return page.evaluate(
    async ({ daemonURL, token, currentPaneCount, targetPaneCount }) => {
      type ControlMessage = Record<string, unknown>;
      type RepositorySnapshot = { id?: string };
      type WorktreeSnapshot = { id?: string };

      const socket = new WebSocket(`${daemonURL}?token=${encodeURIComponent(token)}`);
      socket.binaryType = "arraybuffer";
      const pending = new Map<string, (message: ControlMessage) => void>();

      function encodeJsonControlFrame(value: unknown): ArrayBuffer {
        const payload = new TextEncoder().encode(JSON.stringify(value));
        const frame = new Uint8Array(5 + payload.byteLength);
        const view = new DataView(frame.buffer);
        view.setUint8(0, 0x02);
        view.setUint32(1, payload.byteLength, false);
        frame.set(payload, 5);
        return frame.buffer;
      }

      function decodeJsonControlFrame(frame: ArrayBuffer): ControlMessage {
        const bytes = new Uint8Array(frame);
        const view = new DataView(frame);
        const tag = view.getUint8(0);
        const length = view.getUint32(1, false);
        if (tag !== 0x02 || length !== bytes.byteLength - 5) {
          throw new Error("Invalid JSON control frame");
        }
        return JSON.parse(new TextDecoder().decode(bytes.slice(5))) as ControlMessage;
      }

      function request(type: string, payload: Record<string, unknown>): Promise<ControlMessage> {
        return new Promise((resolve, reject) => {
          const id = crypto.randomUUID();
          const timeout = setTimeout(() => {
            pending.delete(id);
            reject(new Error(`Timed out waiting for ${type}`));
          }, 5_000);
          pending.set(id, (message) => {
            clearTimeout(timeout);
            resolve(message);
          });
          socket.send(encodeJsonControlFrame({ v: 1, id, type, ...payload }));
        });
      }

      socket.addEventListener("message", (event) => {
        if (!(event.data instanceof ArrayBuffer)) {
          return;
        }
        const message = decodeJsonControlFrame(event.data);
        const resolve = pending.get(String(message.id));
        if (resolve) {
          pending.delete(String(message.id));
          resolve(message);
        }
      });

      await new Promise<void>((resolve, reject) => {
        socket.addEventListener("open", () => resolve(), { once: true });
        socket.addEventListener("error", () => reject(new Error("Failed to open daemon websocket")), { once: true });
      });

      try {
        const createdPaneIds: string[] = [];
        const welcome = await request("hello", { token, clientVersion: "e2e", protocolVersion: 1 });
        if (welcome.type !== "welcome") {
          throw new Error(`Unexpected hello response: ${welcome.type}`);
        }
        const repositories = await request("repo.list", {});
        const repoSnapshots = repositories.repositories as RepositorySnapshot[] | undefined;
        const repoId = repoSnapshots?.[0]?.id;
        if (repositories.type !== "repo.listed" || !repoId) {
          throw new Error("Expected at least one repository");
        }
        const worktrees = await request("worktree.list", { repoId });
        const worktreeSnapshots = worktrees.worktrees as WorktreeSnapshot[] | undefined;
        const worktreeId = worktreeSnapshots?.[0]?.id;
        if (worktrees.type !== "worktree.listed" || !worktreeId) {
          throw new Error("Expected at least one worktree");
        }
        for (let index = currentPaneCount; index < targetPaneCount; index += 1) {
          const response = await request("pane.create", { worktreeId, cols: 120, rows: 32 });
          const paneId = response.paneId;
          if (response.type !== "pane.created" || typeof paneId !== "string") {
            throw new Error(`Unexpected pane.create response: ${response.type}`);
          }
          createdPaneIds.push(paneId);
        }
        return createdPaneIds;
      } finally {
        socket.close();
      }
    },
    { daemonURL, token, currentPaneCount, targetPaneCount },
  );
}

async function closePanesThroughBrowser(page: Page, paneIds: string[]): Promise<void> {
  if (paneIds.length === 0) {
    return;
  }

  await page.evaluate(
    async ({ daemonURL, token, paneIds }) => {
      type ControlMessage = Record<string, unknown>;

      const socket = new WebSocket(`${daemonURL}?token=${encodeURIComponent(token)}`);
      socket.binaryType = "arraybuffer";
      const pending = new Map<string, (message: ControlMessage) => void>();

      function encodeJsonControlFrame(value: unknown): ArrayBuffer {
        const payload = new TextEncoder().encode(JSON.stringify(value));
        const frame = new Uint8Array(5 + payload.byteLength);
        const view = new DataView(frame.buffer);
        view.setUint8(0, 0x02);
        view.setUint32(1, payload.byteLength, false);
        frame.set(payload, 5);
        return frame.buffer;
      }

      function decodeJsonControlFrame(frame: ArrayBuffer): ControlMessage {
        const bytes = new Uint8Array(frame);
        const view = new DataView(frame);
        const tag = view.getUint8(0);
        const length = view.getUint32(1, false);
        if (tag !== 0x02 || length !== bytes.byteLength - 5) {
          throw new Error("Invalid JSON control frame");
        }
        return JSON.parse(new TextDecoder().decode(bytes.slice(5))) as ControlMessage;
      }

      function request(type: string, payload: Record<string, unknown>): Promise<ControlMessage> {
        return new Promise((resolve, reject) => {
          const id = crypto.randomUUID();
          const timeout = setTimeout(() => {
            pending.delete(id);
            reject(new Error(`Timed out waiting for ${type}`));
          }, 5_000);
          pending.set(id, (message) => {
            clearTimeout(timeout);
            resolve(message);
          });
          socket.send(encodeJsonControlFrame({ v: 1, id, type, ...payload }));
        });
      }

      socket.addEventListener("message", (event) => {
        if (!(event.data instanceof ArrayBuffer)) {
          return;
        }
        const message = decodeJsonControlFrame(event.data);
        const resolve = pending.get(String(message.id));
        if (resolve) {
          pending.delete(String(message.id));
          resolve(message);
        }
      });

      await new Promise<void>((resolve, reject) => {
        socket.addEventListener("open", () => resolve(), { once: true });
        socket.addEventListener("error", () => reject(new Error("Failed to open daemon websocket")), { once: true });
      });

      try {
        const welcome = await request("hello", { token, clientVersion: "e2e", protocolVersion: 1 });
        if (welcome.type !== "welcome") {
          throw new Error(`Unexpected hello response: ${welcome.type}`);
        }
        for (const paneId of paneIds) {
          const response = await request("pane.close", { paneId });
          if (response.type !== "pane.exited") {
            throw new Error(`Unexpected pane.close response: ${response.type}`);
          }
        }
      } finally {
        socket.close();
      }
    },
    { daemonURL, token, paneIds },
  );
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

async function inputLatencyDurations(page: Page): Promise<number[]> {
  return page.evaluate(() => performance.getEntriesByName("prowl.input.latency").map((entry) => entry.duration));
}

async function echoedCharacterCount(locator: ReturnType<Page["getByRole"]>, character: string): Promise<number> {
  const text = (await locator.textContent()) ?? "";
  return [...text].filter((candidate) => candidate === character).length;
}

function percentile(samples: number[], percentileValue: number): number {
  const sorted = [...samples].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil((percentileValue / 100) * sorted.length) - 1);
  return sorted[index] ?? Number.POSITIVE_INFINITY;
}

async function reconnectDurationsMs(page: Page): Promise<number[]> {
  return page.evaluate(() => performance.getEntriesByName("prowl.ws.reconnect").map((entry) => entry.duration));
}

async function coldStartDurationsMs(page: Page): Promise<number[]> {
  return page.evaluate(() => performance.getEntriesByName("prowl.cold-start").map((entry) => entry.duration));
}

async function paletteOpenDurationsMs(page: Page): Promise<number[]> {
  return page.evaluate(() => performance.getEntriesByName("prowl.palette.open").map((entry) => entry.duration));
}

async function worktreeSwitchDurationsMs(page: Page): Promise<number[]> {
  return page.evaluate(() => performance.getEntriesByName("prowl.worktree.switch").map((entry) => entry.duration));
}

async function htmlDataset(page: Page, key: string): Promise<string | undefined> {
  return page.evaluate((datasetKey) => document.documentElement.dataset[datasetKey], key);
}

async function worktreeNames(page: Page): Promise<string[]> {
  return page.locator("aside[aria-label='Worktrees and tabs'] > section > button > .name").allTextContents();
}

async function worktreeOrder(page: Page, before: string, after: string): Promise<number> {
  const names = await worktreeNames(page);
  return names.indexOf(before) - names.indexOf(after);
}

async function tabTitles(page: Page): Promise<string[]> {
  return page
    .locator(".tabs > button")
    .evaluateAll((buttons) => buttons.map((button) => button.getAttribute("title") ?? ""));
}
