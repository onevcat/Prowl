import type { PaneDescriptor, ServerControlMessage } from "@prowl/protocol";
import { makeMessageId } from "@prowl/protocol";
import { hello, loadCLIConfig, requestDaemon, sendPtyInput } from "../transport";

const textEncoder = new TextEncoder();
const escapeCharacter = String.fromCharCode(27);
const bellCharacter = String.fromCharCode(7);
const csiPattern = new RegExp(`${escapeForRegExp(escapeCharacter)}\\[[0-?]*[ -/]*[@-~]`, "g");
const oscPattern = new RegExp(
  `${escapeForRegExp(escapeCharacter)}\\][^${escapeForRegExp(bellCharacter)}]*(?:${escapeForRegExp(bellCharacter)}|${escapeForRegExp(escapeCharacter)}\\\\)`,
  "g",
);
const captureTimeoutMs = 3000;
const capturePollIntervalMs = 50;
const promptReadyPatterns = [/(^|\r?\n)[^\r\n]*[$%#❯>]\s*$/m, /tokens used/i, /\b(done|complete|finished)\b/i];

export type PaneReadResult = { paneId: string; output: string };
export type PaneSendResult = { paneId: string; status: "sent"; command: string; output?: string };
export type PaneKeyResult = { paneId: string; status: "sent"; key: string };
export type PaneNewResult = { paneId: string; worktreeId: string; channelId: number; title: string };
export type PaneCloseResult = { paneId: string; status: "closed"; exitCode: number };

export async function renderPaneRead(paneId: string | undefined): Promise<string> {
  return (await readPane(paneId)).output;
}

export async function readPane(paneId: string | undefined): Promise<PaneReadResult> {
  const pane = await requirePane(paneId);
  return { paneId: pane.id, output: await replayForPane(pane.id) };
}

export async function sendPaneCommand(paneId: string | undefined, command: string | undefined): Promise<string> {
  const result = await sendPaneCommandResult(paneId, command);
  if (result.output !== undefined) {
    return result.output;
  }
  return `sent\t${result.paneId}`;
}

export async function sendPaneCommandResult(
  paneId: string | undefined,
  command: string | undefined,
): Promise<PaneSendResult> {
  return sendPaneCommandWithOptions(paneId, command, { capture: false });
}

export async function sendPaneCommandWithOptions(
  paneId: string | undefined,
  command: string | undefined,
  options: { capture: boolean },
): Promise<PaneSendResult> {
  if (!command) {
    throw new Error('Usage: prowl send <paneId> "<command>" [--capture]');
  }
  const pane = await requirePane(paneId);
  const before = options.capture ? await replayForPane(pane.id) : "";
  await sendPtyInput(pane.channelId, textEncoder.encode(`${command}\r`));
  if (!options.capture) {
    return { paneId: pane.id, status: "sent", command };
  }
  return { paneId: pane.id, status: "sent", command, output: await capturePaneOutput(pane.id, before) };
}

export async function sendPaneKey(paneId: string | undefined, key: string | undefined): Promise<string> {
  const result = await sendPaneKeyResult(paneId, key);
  return `sent\t${result.paneId}\t${result.key}`;
}

export async function sendPaneKeyResult(paneId: string | undefined, key: string | undefined): Promise<PaneKeyResult> {
  if (!key) {
    throw new Error("Usage: prowl key <paneId> <keystroke>");
  }
  const pane = await requirePane(paneId);
  await sendPtyInput(pane.channelId, keyBytes(key));
  return { paneId: pane.id, status: "sent", key };
}

export async function renderPaneNew(args: string[]): Promise<string> {
  const response = await createPane(args);
  return `${response.paneId}\t${response.worktreeId}\t${response.channelId}\t${response.title}`;
}

export async function createPane(args: string[]): Promise<PaneNewResult> {
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
  return {
    paneId: response.paneId,
    worktreeId: response.worktreeId,
    channelId: response.channelId,
    title: response.title ?? "Shell",
  };
}

export async function closePane(paneId: string | undefined): Promise<string> {
  const response = await closePaneResult(paneId);
  return `closed\t${response.paneId}`;
}

export async function closePaneResult(paneId: string | undefined): Promise<PaneCloseResult> {
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
  return { paneId: response.paneId, status: "closed", exitCode: response.exitCode };
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

async function replayForPane(paneId: string): Promise<string> {
  const response = await requestDaemon({
    v: 1,
    type: "pane.attach",
    id: makeMessageId(),
    paneId,
  });
  if (response.type !== "pane.replay") {
    throw new Error(`Unexpected daemon response: ${response.type}`);
  }
  return Buffer.from(response.bytes, "base64").toString("utf8");
}

async function capturePaneOutput(paneId: string, previousOutput: string): Promise<string> {
  const deadline = performance.now() + captureTimeoutMs;
  let latest = previousOutput;
  while (performance.now() < deadline) {
    latest = await replayForPane(paneId);
    const captured = outputSince(latest, previousOutput);
    if (captured && isPromptReady(captured)) {
      return latest;
    }
    await Bun.sleep(capturePollIntervalMs);
  }
  return latest;
}

function outputSince(current: string, previous: string): string {
  return current.startsWith(previous) ? current.slice(previous.length) : current;
}

function isPromptReady(output: string): boolean {
  const tail = stripTerminalControls(output.slice(-4096));
  return promptReadyPatterns.some((pattern) => pattern.test(tail));
}

function stripTerminalControls(text: string): string {
  return text.replace(csiPattern, "").replace(oscPattern, "").replace(/\r/g, "\n");
}

function escapeForRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
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
