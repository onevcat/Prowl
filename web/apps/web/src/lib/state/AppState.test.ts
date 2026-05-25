import { interactionMeasureNames } from "$lib/performance/marks";
import type { CustomAction } from "@prowl/protocol";
import { afterEach, describe, expect, test } from "vitest";
import {
  AppState,
  applyPaneDescriptor,
  bootstrapSettingsKeys,
  cachedPaneDescriptorsForWorktrees,
  commandHistoryKey,
  commandPaletteItemId,
  customActionsForRepositories,
  isPersistableAppView,
  openTabsKey,
  paneDescriptorsByWorktree,
  paneIdsOutsideWorktrees,
  systemPaneId,
} from "./AppState.svelte";
import { Pane } from "./Pane.svelte";
import type { Repository, Worktree } from "./types";

const globalWithRunes = globalThis as typeof globalThis & {
  $state?: <T>(value: T) => T;
};

globalWithRunes.$state = ((value: unknown) => value) as typeof globalWithRunes.$state;

Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: { platform: "Linux" },
});

const originalRequestAnimationFrame = globalThis.requestAnimationFrame;
const originalFetch = globalThis.fetch;

afterEach(() => {
  performance.clearMeasures();
  Object.defineProperty(globalThis, "fetch", {
    configurable: true,
    value: originalFetch,
  });
  if (originalRequestAnimationFrame) {
    Object.defineProperty(globalThis, "requestAnimationFrame", {
      configurable: true,
      value: originalRequestAnimationFrame,
    });
    return;
  }
  Reflect.deleteProperty(globalThis, "requestAnimationFrame");
});

describe("AppState ordering", () => {
  test("orders worktrees and panes according to drag reorder state", () => {
    const state = appStateFixture();

    state.reorderWorktree("repo-1", "worktree-2", "worktree-1");
    state.reorderPane("worktree-1", "pane-2", "pane-1");

    expect(state.orderedWorktrees("repo-1").map((worktree) => worktree.id)).toEqual(["worktree-2", "worktree-1"]);
    expect(state.orderedPanes("worktree-1").map((pane) => pane.id)).toEqual(["pane-2", "pane-1"]);
  });

  test("selecting a worktree selects the first pane in the user-defined tab order", () => {
    const state = appStateFixture();
    state.reorderPane("worktree-1", "pane-2", "pane-1");

    state.selectWorktree("worktree-1");

    expect(state.selectedPaneId).toBe("pane-2");
  });
});

describe("AppState pane persistence helpers", () => {
  test("builds the WEB.md open tabs key for a worktree", () => {
    expect(openTabsKey("worktree-1")).toBe("prowl:ui.openTabs.worktree-1");
  });

  test("groups pane descriptors by worktree for IndexedDB persistence", () => {
    const first = pane("pane-1", 1);
    const second = pane("pane-2", 2);
    const third = new Pane({
      ...second.descriptor,
      id: "pane-3",
      channelId: 3,
      worktreeId: "worktree-2",
      title: "third",
    });

    const grouped = paneDescriptorsByWorktree([first, second, third]);

    expect(grouped.get("worktree-1")?.map((descriptor) => descriptor.id)).toEqual(["pane-1", "pane-2"]);
    expect(grouped.get("worktree-2")?.map((descriptor) => descriptor.id)).toEqual(["pane-3"]);
  });

  test("filters cached open tab descriptors to known worktrees", () => {
    const cached = cachedPaneDescriptorsForWorktrees(
      [
        [
          pane("pane-1", 1).descriptor,
          { ...pane("pane-2", 2).descriptor, worktreeId: "missing-worktree" },
          { ...pane("pane-3", 3).descriptor, channelId: 0 },
        ],
        "not an array",
      ],
      new Set(["worktree-1"]),
    );

    expect(cached.map((descriptor) => descriptor.id)).toEqual(["pane-1"]);
  });

  test("identifies panes whose worktrees disappeared", () => {
    const panes = [pane("pane-1", 1).descriptor, { ...pane("pane-2", 2).descriptor, worktreeId: "missing-worktree" }];

    expect(paneIdsOutsideWorktrees(panes, [worktree("worktree-1", "one")])).toEqual(["pane-2"]);
  });

  test("filters repo-scoped custom actions to registered repositories", () => {
    const actions = [
      customAction("global", null, "Mod+G"),
      customAction("repo", "repo-1", "Mod+R"),
      customAction("missing", "missing-repo", "Mod+M"),
    ];

    expect(customActionsForRepositories(actions, [{ id: "repo-1" }]).map((action) => action.id)).toEqual([
      "global",
      "repo",
    ]);
  });

  test("applies pane metadata updates without replacing buffered output", () => {
    const existing = pane("pane-1", 1);
    existing.output = "first line\nsecond line";

    applyPaneDescriptor(existing, {
      ...existing.descriptor,
      title: "Updated action",
      taskStatus: "done",
      unread: true,
      lastOutputLine: "completed",
      updatedAt: 42,
    });

    expect(existing.output).toBe("first line\nsecond line");
    expect(existing.title).toBe("Updated action");
    expect(existing.taskStatus).toBe("done");
    expect(existing.unread).toBe(true);
    expect(existing.lastOutputLine).toBe("completed");
    expect(existing.updatedAt).toBe(42);
  });
});

describe("AppState bootstrap protocol", () => {
  test("keeps pane listing out of the settings snapshot request", () => {
    expect(bootstrapSettingsKeys).toEqual(["appearance", "shortcuts", "advanced"]);
    expect(bootstrapSettingsKeys).not.toContain("panes");
  });

  test("persists only WEB.md workspace views", () => {
    expect(isPersistableAppView("shelf")).toBe(true);
    expect(isPersistableAppView("canvas")).toBe(true);
    expect(isPersistableAppView("settings")).toBe(false);
    expect(isPersistableAppView("diff")).toBe(false);
  });
});

describe("AppState worktree spine state", () => {
  test("derives unread count from panes when pane metadata is loaded", () => {
    const state = appStateFixture();
    const secondPane = state.panes.get("pane-2");
    expect(secondPane).toBeDefined();
    if (!secondPane) {
      return;
    }
    secondPane.unread = true;

    expect(state.worktreeUnreadCount("worktree-1")).toBe(1);

    state.selectPane("pane-2");

    expect(state.worktreeUnreadCount("worktree-1")).toBe(0);
  });

  test("derives task status from pane severity before falling back to worktree metadata", () => {
    const state = appStateFixture();
    const firstPane = state.panes.get("pane-1");
    const secondPane = state.panes.get("pane-2");
    expect(firstPane).toBeDefined();
    expect(secondPane).toBeDefined();
    if (!firstPane || !secondPane) {
      return;
    }
    firstPane.taskStatus = "done";
    secondPane.taskStatus = "running";

    expect(state.worktreeTaskStatus("worktree-1")).toBe("running");

    secondPane.taskStatus = "failed";

    expect(state.worktreeTaskStatus("worktree-1")).toBe("failed");
    expect(state.worktreeTaskStatus("worktree-2")).toBe("idle");
  });
});

describe("AppState focus-aware notifications", () => {
  test("treats the selected pane as focused only while the app is focused", () => {
    const state = appStateFixture();

    expect(state.isPaneFocused("pane-1")).toBe(true);

    state.setAppFocused(false);

    expect(state.isPaneFocused("pane-1")).toBe(false);
    expect(state.isPaneFocused("pane-2")).toBe(false);
  });

  test("clears selected pane unread state when focus returns", () => {
    const state = appStateFixture();
    const selectedPane = state.panes.get("pane-1");
    expect(selectedPane).toBeDefined();
    if (!selectedPane) {
      return;
    }
    selectedPane.unread = true;
    state.setAppFocused(false);

    state.setAppFocused(true);

    expect(selectedPane.unread).toBe(false);
  });

  test("notifies when an unfocused pane transitions to done", async () => {
    const notifications = installNotificationFakes();
    const state = appStateFixture();
    const pane = state.panes.get("pane-2");
    expect(pane).toBeDefined();
    if (!pane) {
      return;
    }
    pane.taskStatus = "running";
    pane.lastOutputLine = "Tests passed";
    state.ws.request = (() => Promise.resolve({ v: 1, type: "pong", id: "test" })) as AppState["ws"]["request"];

    await state.updatePaneStatus("pane-2", "done");

    expect(notifications).toEqual([{ title: "pane-2", body: "pane-2: Tests passed" }]);
  });

  test("does not notify when the focused pane transitions to done", async () => {
    const notifications = installNotificationFakes();
    const state = appStateFixture();
    const pane = state.panes.get("pane-1");
    expect(pane).toBeDefined();
    if (!pane) {
      return;
    }
    pane.taskStatus = "running";
    pane.lastOutputLine = "Done";
    state.ws.request = (() => Promise.resolve({ v: 1, type: "pong", id: "test" })) as AppState["ws"]["request"];

    await state.updatePaneStatus("pane-1", "done");

    expect(notifications).toEqual([]);
  });

  test("shows daemon notifications for unfocused panes", () => {
    const notifications = installNotificationFakes();
    const state = appStateFixture();
    const pane = state.panes.get("pane-2");
    expect(pane).toBeDefined();
    if (!pane) {
      return;
    }

    state.handleServerNotification({
      v: 1,
      type: "notification",
      id: "8b8e9af6-56b8-4da4-8146-4a9319216522",
      severity: "info",
      title: "Task finished",
      body: "pane-2: Tests passed",
      paneId: "pane-2",
    });

    expect(notifications).toEqual([{ title: "Task finished", body: "pane-2: Tests passed" }]);
    expect(pane.unread).toBe(true);
  });

  test("ignores daemon notifications for the focused pane", () => {
    const notifications = installNotificationFakes();
    const state = appStateFixture();
    const pane = state.panes.get("pane-1");
    expect(pane).toBeDefined();
    if (!pane) {
      return;
    }

    state.handleServerNotification({
      v: 1,
      type: "notification",
      id: "4c64c9b3-7395-462c-98d9-e48890830ee1",
      severity: "info",
      title: "Task finished",
      body: "pane-1: Done",
      paneId: "pane-1",
    });

    expect(notifications).toEqual([]);
    expect(pane.unread).toBe(false);
  });

  test("deduplicates daemon notifications already handled locally", async () => {
    const notifications = installNotificationFakes();
    const state = appStateFixture();
    const pane = state.panes.get("pane-2");
    expect(pane).toBeDefined();
    if (!pane) {
      return;
    }
    pane.taskStatus = "running";
    pane.lastOutputLine = "Tests passed";
    state.ws.request = (async (message) => {
      state.handleServerNotification({
        v: 1,
        type: "notification",
        id: message.id,
        severity: "info",
        title: "Task finished",
        body: "pane-2: Tests passed",
        paneId: "pane-2",
      });
      return { v: 1, type: "pong", id: message.id };
    }) as AppState["ws"]["request"];

    await state.updatePaneStatus("pane-2", "done");

    expect(notifications).toEqual([{ title: "pane-2", body: "pane-2: Tests passed" }]);
  });

  test("detects task status from terminal parsed output", () => {
    const state = appStateFixture();
    const pane = state.panes.get("pane-1");
    expect(pane).toBeDefined();
    if (!pane) {
      return;
    }
    state.ws.request = (() => Promise.resolve({ v: 1, type: "pong", id: "test" })) as AppState["ws"]["request"];

    state.detectPaneStatusFromTerminal("pane-1", "Thinking about the next edit");

    expect(pane.taskStatus).toBe("running");
  });
});

describe("AppState custom action shortcuts", () => {
  test("ignores repo-scoped custom action shortcuts outside the selected repo", () => {
    const state = appStateFixture();
    state.customActions = [customAction("action-other", "repo-2", "Mod+R")];
    const event = shortcutEvent({ key: "r", ctrlKey: true });
    let ranActionId: string | null = null;
    state.runCustomAction = (async (actionId: string) => {
      ranActionId = actionId;
    }) as AppState["runCustomAction"];

    state.handleKeydown(event);

    expect(event.prevented).toBe(false);
    expect(ranActionId).toBeNull();
  });

  test("runs global custom action shortcuts", () => {
    const state = appStateFixture();
    state.customActions = [customAction("action-global", null, "Mod+R")];
    const event = shortcutEvent({ key: "r", ctrlKey: true });
    let ranActionId: string | null = null;
    state.runCustomAction = (async (actionId: string) => {
      ranActionId = actionId;
    }) as AppState["runCustomAction"];

    state.handleKeydown(event);

    expect(event.prevented).toBe(true);
    expect(ranActionId).toBe("action-global");
  });
});

describe("AppState custom action palette items", () => {
  test("runs only runnable custom actions from the command palette", () => {
    const state = appStateFixture();
    state.customActions = [
      customAction("action-global", null, "Mod+G"),
      customAction("action-repo", "repo-1", "Mod+R"),
      customAction("action-other", "repo-2", "Mod+O"),
    ];
    let ranActionId: string | null = null;
    state.runCustomAction = (async (actionId: string) => {
      ranActionId = actionId;
    }) as AppState["runCustomAction"];

    const actionItems = state.paletteItems.filter((item) => item.id.startsWith("action:"));
    const repoAction = actionItems.find((item) => item.id === "action:action-repo");

    expect(actionItems.map((item) => item.id)).toEqual(["action:action-global", "action:action-repo"]);
    expect(repoAction).toBeDefined();
    if (!repoAction) {
      return;
    }

    state.invokePaletteItem(repoAction);

    expect(ranActionId).toBe("action-repo");
    expect(state.paletteHistory[0]).toMatchObject({
      id: "action:action-repo",
      section: "Actions",
      title: "action-repo",
    });
  });
});

describe("AppState command history search", () => {
  test("builds the WEB.md command history storage key", () => {
    expect(commandHistoryKey).toBe("prowl:palette.history");
  });

  test("records completed terminal commands and exposes them to palette search", () => {
    const state = appStateFixture();
    const sentInputs: string[] = [];
    state.ws.sendBinary = ((channelId: number, payload: Uint8Array) => {
      sentInputs.push(`${channelId}:${new TextDecoder().decode(payload)}`);
      return true;
    }) as AppState["ws"]["sendBinary"];

    state.sendInputToPane("pane-1", "printf command-history");
    expect(state.commandHistory).toEqual([]);

    state.sendInputToPane("pane-1", "\r");

    expect(state.commandHistory.map((entry) => entry.command)).toEqual(["printf command-history"]);
    const historyItem = state.paletteItems.find((item) => item.id === commandPaletteItemId("printf command-history"));

    expect(historyItem).toMatchObject({
      section: "Recent",
      subtitle: "Command history",
      title: "printf command-history",
    });

    historyItem?.invoke();

    expect(sentInputs.at(-1)).toBe("1:printf command-history\n");
  });

  test("deduplicates broadcast command history across visible panes", () => {
    const state = appStateFixture();
    state.view = "canvas";
    state.ws.sendBinary = (() => true) as AppState["ws"]["sendBinary"];

    state.sendInputToVisiblePanes("printf all-panes\n");

    expect(state.commandHistory.map((entry) => entry.command)).toEqual(["printf all-panes"]);
  });

  test("honors terminal backspace while recording command history", () => {
    const state = appStateFixture();
    state.ws.sendBinary = (() => true) as AppState["ws"]["sendBinary"];

    state.sendInputToPane("pane-1", "printf typo");
    state.sendInputToPane("pane-1", "\x7f\x7f\x7fok\n");

    expect(state.commandHistory.map((entry) => entry.command)).toEqual(["printf tok"]);
  });

  test("ignores terminal escape sequences while recording command history", () => {
    const state = appStateFixture();
    state.ws.sendBinary = (() => true) as AppState["ws"]["sendBinary"];

    state.sendInputToPane("pane-1", "\x1b[Aprintf clean\n");

    expect(state.commandHistory.map((entry) => entry.command)).toEqual(["printf clean"]);
  });
});

describe("AppState view mutation methods", () => {
  test("opens and closes the palette through actions", () => {
    const state = appStateFixture();

    state.perform("palette.open");
    expect(state.paletteOpen).toBe(true);

    state.setPaletteQuery("repo");
    expect(state.paletteQuery).toBe("repo");

    state.perform("palette.close");
    expect(state.paletteOpen).toBe(false);
    expect(state.paletteQuery).toBe("");
  });

  test("closes the palette with Escape even when terminal input has focus", () => {
    const state = appStateFixture();
    const event = shortcutEvent({
      key: "Escape",
      target: {
        closest: (selector: string) => (selector.includes("input") ? {} : null),
      } as unknown as EventTarget,
    });

    state.perform("palette.open");
    state.setPaletteQuery("repo");
    state.handleKeydown(event);

    expect(event.prevented).toBe(true);
    expect(state.paletteOpen).toBe(false);
    expect(state.paletteQuery).toBe("");
  });

  test("records worktree switch performance measures", () => {
    const state = appStateFixture();

    state.selectWorktree("worktree-1");

    expect(state.metrics.worktreeSwitchSamples).toHaveLength(1);
    expect(performance.getEntriesByName(interactionMeasureNames.worktreeSwitch)).toHaveLength(1);
  });

  test("records palette open performance after the next frame", async () => {
    Object.defineProperty(globalThis, "requestAnimationFrame", {
      configurable: true,
      value: (callback: FrameRequestCallback) => {
        queueMicrotask(() => callback(performance.now()));
        return 1;
      },
    });
    const state = appStateFixture();

    state.perform("palette.open");
    await Promise.resolve();

    expect(state.metrics.paletteOpenSamples).toHaveLength(1);
    expect(performance.getEntriesByName(interactionMeasureNames.paletteOpen)).toHaveLength(1);
  });

  test("runs the diff action through the native-aligned shortcut", () => {
    const state = appStateFixture();
    const event = shortcutEvent({ key: "y", ctrlKey: true, shiftKey: true });
    let diffWorktreeId: string | null = null;
    state.showDiff = (async (worktreeId = state.selectedWorktreeId) => {
      diffWorktreeId = worktreeId;
    }) as AppState["showDiff"];

    state.handleKeydown(event);

    expect(event.prevented).toBe(true);
    expect(diffWorktreeId).toBe("worktree-1");
  });

  test("runs native Mod-Control actions through non-Apple aliases", () => {
    const state = appStateFixture();
    const event = shortcutEvent({ key: "ArrowDown", ctrlKey: true, altKey: true });

    state.handleKeydown(event);

    expect(event.prevented).toBe(true);
    expect(state.selectedPaneId).toBe("pane-2");
  });

  test("runs pane close through the shortcut action", () => {
    const state = appStateFixture();
    const event = shortcutEvent({ key: "w", ctrlKey: true });
    let closed = false;
    state.closeSelectedPane = (async () => {
      closed = true;
    }) as AppState["closeSelectedPane"];

    state.handleKeydown(event);

    expect(event.prevented).toBe(true);
    expect(closed).toBe(true);
  });

  test("records streaming archive progress from the daemon", () => {
    const state = appStateFixture();

    state.applyWorktreeArchiveProgress(
      {
        v: 1,
        type: "worktree.archiveProgress",
        id: "archive-1",
        worktreeId: "worktree-1",
        step: "removing",
        message: "Removing worktree",
      },
      1234,
    );

    expect(state.archiveProgressByWorktree["worktree-1"]).toEqual({
      worktreeId: "worktree-1",
      step: "removing",
      message: "Removing worktree",
      updatedAt: 1234,
    });
    expect(state.latestArchiveProgress).toEqual(state.archiveProgressByWorktree["worktree-1"]);
    expect(state.errorMessage).toBeNull();
  });

  test("subscribes to the hidden system pane before git worktree operations", async () => {
    const state = appStateFixture();
    const requests: string[] = [];
    state.ws.request = ((message) => {
      requests.push(message.type);
      if (message.type === "pane.attach") {
        expect(message.paneId).toBe(systemPaneId);
        return Promise.resolve({
          v: 1,
          type: "pane.replay",
          id: message.id,
          paneId: systemPaneId,
          bytes: btoa("git output from daemon\n"),
        });
      }
      if (message.type === "worktree.create") {
        return Promise.resolve({
          v: 1,
          type: "worktree.updated",
          id: message.id,
          worktree: worktree("worktree-3", "three"),
        });
      }
      return Promise.resolve({ v: 1, type: "pong", id: message.id });
    }) as AppState["ws"]["request"];

    await state.createWorktree("repo-1", "feature/system-output");

    expect(requests).toEqual(["pane.attach", "worktree.create"]);
    expect(state.systemOutput).toContain("git output from daemon");
    expect(state.systemLastOutputLine).toBe("git output from daemon");
  });

  test("prevents browser defaults for unmatched terminal key events", () => {
    const state = appStateFixture();
    const event = shortcutEvent({ key: "l", ctrlKey: true, target: terminalInputTarget() });

    state.handleKeydown(event);

    expect(event.prevented).toBe(true);
  });

  test("updates auth form state through methods", () => {
    const state = appStateFixture();

    state.setDaemonURL("ws://127.0.0.1:9999/ws");
    state.setLoginToken("secret");
    state.setLoginRemember(true);

    expect(state.daemonURL).toBe("ws://127.0.0.1:9999/ws");
    expect(state.loginToken).toBe("secret");
    expect(state.loginRemember).toBe(true);
  });

  test("clears typed login tokens after remember-me failures", async () => {
    const state = appStateFixture();
    state.setDaemonURL("ws://127.0.0.1:7878/ws");
    state.setLoginToken("super-secret-token");
    state.setLoginRemember(true);
    Object.defineProperty(globalThis, "fetch", {
      configurable: true,
      value: () => Promise.resolve(new Response("Unauthorized", { status: 401 })),
    });

    await state.login();

    expect(state.loginToken).toBe("");
    expect(state.loginError).toBe("Invalid token.");
    expect(state.loginError).not.toContain("super-secret-token");
  });
});

describe("AppState renderer pool", () => {
  test("keeps fifty visible panes under the WebGL context limit while preserving the focused pane", () => {
    const state = appStateFixture();
    const panes = Array.from({ length: 50 }, (_, index) => pane(`pane-${index + 1}`, index + 1));
    state.panes = new Map(panes.map((candidate) => [candidate.id, candidate]));
    state.view = "canvas";
    state.selectedPaneId = "pane-50";
    state.ws.request = (() => Promise.resolve({ v: 1, type: "pong", id: "test" })) as AppState["ws"]["request"];

    state.syncRenderedPanes();

    expect(state.visiblePanes).toHaveLength(50);
    expect(state.activeRendererCount).toBe(state.rendererLimit);
    expect(state.renderablePaneIds.has("pane-50")).toBe(true);
  });
});

function appStateFixture(): AppState {
  const state = new AppState();
  const repository: Repository = {
    id: "repo-1",
    path: "/repo",
    displayName: "Repo",
    color: "#0a84ff",
  };
  const worktrees: Worktree[] = [worktree("worktree-1", "one"), worktree("worktree-2", "two")];

  state.repositories = [repository];
  state.worktreesByRepo = new Map([["repo-1", worktrees]]);
  state.panes = new Map([
    ["pane-1", pane("pane-1", 1)],
    ["pane-2", pane("pane-2", 2)],
  ]);
  state.selectedWorktreeId = "worktree-1";
  state.selectedPaneId = "pane-1";
  state.setAppFocused(true);

  return state;
}

function worktree(id: string, name: string): Worktree {
  return {
    id,
    repoId: "repo-1",
    path: `/repo/${name}`,
    name,
    branch: "main",
    status: "clean",
    taskStatus: "idle",
    unreadCount: 0,
  };
}

function pane(id: string, channelId: number): Pane {
  return new Pane({
    id,
    channelId,
    worktreeId: "worktree-1",
    title: id,
    taskStatus: "idle",
    unread: false,
    lastOutputLine: "",
    updatedAt: 0,
  });
}

function customAction(id: string, repoId: string | null, shortcut: string): CustomAction {
  return {
    id,
    repoId,
    name: id,
    command: "printf action",
    shortcut,
    outputMode: "currentPane",
    ordering: 0,
  };
}

type ShortcutEvent = KeyboardEvent & {
  prevented: boolean;
};

function shortcutEvent(overrides: Partial<KeyboardEvent> = {}): ShortcutEvent {
  return {
    altKey: false,
    ctrlKey: false,
    defaultPrevented: false,
    key: "r",
    metaKey: false,
    prevented: false,
    shiftKey: false,
    target: null,
    preventDefault() {
      this.prevented = true;
    },
    ...overrides,
  } as ShortcutEvent;
}

function terminalInputTarget(): EventTarget {
  return new (class extends EventTarget {
    closest(selector = ""): unknown {
      return selector === ".terminal" ? this : null;
    }
  })();
}

function installNotificationFakes(): Array<{ title: string; body: string }> {
  const notifications: Array<{ title: string; body: string }> = [];
  class TestNotification {
    static permission: NotificationPermission = "granted";

    constructor(title: string, options?: NotificationOptions) {
      notifications.push({ title, body: options?.body ?? "" });
    }
  }
  Object.defineProperty(globalThis, "Notification", {
    configurable: true,
    value: TestNotification,
  });
  Object.defineProperty(globalThis, "Audio", {
    configurable: true,
    value: class {
      play(): Promise<void> {
        return Promise.resolve();
      }
    },
  });
  return notifications;
}
