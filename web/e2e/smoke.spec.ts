import { type APIRequestContext, expect, test } from "@playwright/test";

const daemonURL = "ws://127.0.0.1:7879/ws";
const daemonHTTPURL = "http://127.0.0.1:7879";
const token = "e2e-token";

test.describe.configure({ mode: "serial" });

test("logs in with a daemon token", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}`);

  await expect(page.getByRole("heading", { name: "Connect to prowld" })).toBeVisible();
  await page.getByLabel("Token").fill(token);
  await page.getByRole("button", { name: "Connect" }).click();

  await expect(page.locator(".connection.open")).toBeVisible();
  await expect(page.getByRole("textbox", { name: "Shell" })).toBeVisible();
});

test("connects to the daemon and writes through the terminal", async ({ page }) => {
  await page.goto(`/?daemon=${encodeURIComponent(daemonURL)}&token=${token}`);

  await expect(page.locator(".connection.open")).toBeVisible();
  const terminal = page.getByRole("textbox", { name: "Shell" });
  await expect(terminal).toBeVisible();

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

async function debugStats(request: APIRequestContext): Promise<{
  paneAttachRequests: number;
  paneCreateRequests: number;
}> {
  const response = await request.get(`${daemonHTTPURL}/debug/stats`);
  return (await response.json()) as { paneAttachRequests: number; paneCreateRequests: number };
}
