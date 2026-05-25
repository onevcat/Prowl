import { interactionMeasureNames } from "$lib/performance/marks";
import type { CustomAction } from "@prowl/protocol";
import { afterEach, describe, expect, test } from "vitest";
import { AppState, openTabsKey, paneDescriptorsByWorktree } from "./AppState.svelte";
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

afterEach(() => {
  performance.clearMeasures();
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

  test("updates auth form state through methods", () => {
    const state = appStateFixture();

    state.setDaemonURL("ws://127.0.0.1:9999/ws");
    state.setLoginToken("secret");

    expect(state.daemonURL).toBe("ws://127.0.0.1:9999/ws");
    expect(state.loginToken).toBe("secret");
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
