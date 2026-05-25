import type { PaneDescriptor, ServerControlMessage } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";
import { hello, loadCLIConfig, requestDaemon, sendPtyInput } from "../transport";

const textEncoder = new TextEncoder();

export async function renderPaneRead(paneId: string | undefined): Promise<string> {
  const pane = await requirePane(paneId);
  const response = await requestDaemon({
    v: 1,
    type: "pane.attach",
    id: makeMessageId(),
    paneId: pane.id,
  });
  if (response.type !== "pane.replay") {
    throw new Error(`Unexpected daemon response: ${response.type}`);
  }
  return Buffer.from(response.bytes, "base64").toString("utf8");
}

export async function sendPaneCommand(paneId: string | undefined, command: string | undefined): Promise<string> {
  if (!command) {
    throw new Error('Usage: prowl send <paneId> "<command>"');
  }
  const pane = await requirePane(paneId);
  await sendPtyInput(pane.channelId, textEncoder.encode(`${command}\r`));
  return `sent\t${pane.id}`;
}

export async function sendPaneKey(paneId: string | undefined, key: string | undefined): Promise<string> {
  if (!key) {
    throw new Error("Usage: prowl key <paneId> <keystroke>");
  }
  const pane = await requirePane(paneId);
  await sendPtyInput(pane.channelId, keyBytes(key));
  return `sent\t${pane.id}\t${key}`;
}

export async function renderPaneNew(args: string[]): Promise<string> {
  const worktreeIndex = args.indexOf("--worktree");
  const commandIndex = args.indexOf("--command");
  const worktreeId = worktreeIndex === -1 ? undefined : args[worktreeIndex + 1];
  if (!worktreeId) {
    throw new Error("Usage: prowl new --worktree <id> [--command <command>]");
  }
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({
    v: 1,
    type: "pane.create",
    id: makeMessageId(),
    worktreeId,
    cols: 120,
    rows: 32,
    command: commandIndex === -1 ? undefined : args.slice(commandIndex + 1).join(" "),
  });
  if (response.type !== "pane.created") {
    throw new Error(`Unexpected daemon response: ${response.type}`);
  }
  return `${response.paneId}\t${response.worktreeId}\t${response.channelId}\t${response.title ?? "Shell"}`;
}

export async function closePane(paneId: string | undefined): Promise<string> {
  if (!paneId) {
    throw new Error("Usage: prowl close <paneId>");
  }
  const config = await loadCLIConfig();
  await hello(config.token);
  const response = await requestDaemon({
    v: 1,
    type: "pane.close",
    id: makeMessageId(),
    paneId,
  });
  if (response.type !== "pane.exited") {
    throw new Error(`Unexpected daemon response: ${response.type}`);
  }
  return `closed\t${response.paneId}`;
}

async function requirePane(paneId: string | undefined): Promise<PaneDescriptor> {
  if (!paneId) {
    throw new Error("Pane id is required");
  }
  const config = await loadCLIConfig();
  await hello(config.token);
  const panes = await listPanes();
  const pane = panes.find((candidate) => candidate.id === paneId);
  if (!pane) {
    throw new Error(`Pane not found: ${paneId}`);
  }
  return pane;
}

async function listPanes(): Promise<PaneDescriptor[]> {
  const response = await requestDaemon({
    v: 1,
    type: "settings.get",
    id: makeMessageId(),
    keys: ["panes"],
  });
  return panesFromResponse(response);
}

function panesFromResponse(response: ServerControlMessage): PaneDescriptor[] {
  if (response.type !== "settings.snapshot" || !Array.isArray(response.settings.panes)) {
    return [];
  }
  return response.settings.panes as PaneDescriptor[];
}

function keyBytes(key: string): Uint8Array {
  const normalized = key.toLowerCase();
  if (normalized === "enter") {
    return textEncoder.encode("\r");
  }
  if (normalized === "tab") {
    return textEncoder.encode("\t");
  }
  if (normalized === "escape" || normalized === "esc") {
    return textEncoder.encode("\x1b");
  }
  if (normalized === "backspace") {
    return textEncoder.encode("\x7f");
  }
  const control = normalized.match(/^c-([a-z])$/);
  const controlKey = control?.[1];
  if (controlKey) {
    return Uint8Array.of(controlKey.charCodeAt(0) - 96);
  }
  return textEncoder.encode(key);
}
