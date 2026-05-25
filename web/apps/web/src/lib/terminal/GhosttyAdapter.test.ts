import { afterEach, describe, expect, test, vi } from "vitest";
import {
  resetTerminalAdaptersForTests,
  syncTerminalThemeForPreference,
  terminalAdapterForPane,
  terminalThemeForPreference,
} from "./GhosttyAdapter";

type FakeTerminal = {
  element: HTMLElement | null;
  options: { theme: { background: string } };
  disposed: boolean;
};

vi.mock("ghostty-web", () => {
  const instances: FakeTerminal[] = [];

  class Terminal {
    element: HTMLElement | null = null;
    disposed = false;
    options: { theme: { background: string } };

    constructor(options: { theme: { background: string } }) {
      this.options = options;
      instances.push(this);
    }

    open(element: HTMLElement): void {
      this.element = element;
    }

    loadAddon(): void {}
    write(): void {}
    reset(): void {}
    resize(): void {}
    focus(): void {}

    dispose(): void {
      this.disposed = true;
    }

    onData(): { dispose(): void } {
      return { dispose: () => undefined };
    }

    onResize(): { dispose(): void } {
      return { dispose: () => undefined };
    }

    onTitleChange(): { dispose(): void } {
      return { dispose: () => undefined };
    }
  }

  class FitAddon {
    observeResize(): void {}
    fit(): void {}
  }

  return {
    FitAddon,
    Terminal,
    __instances: instances,
    init: vi.fn(() => Promise.resolve()),
  };
});

afterEach(() => {
  resetTerminalAdaptersForTests();
});

describe("Ghostty terminal theme sync", () => {
  test("maps system, light, and dark preferences to terminal themes", () => {
    expect(terminalThemeForPreference("light").background).toBe("#ffffff");
    expect(terminalThemeForPreference("dark").background).toBe("#111111");
    expect(terminalThemeForPreference("system", false).background).toBe("#ffffff");
    expect(terminalThemeForPreference("system", true).background).toBe("#111111");
  });

  test("updates an existing terminal theme without recreating the instance", async () => {
    const ghosttyWeb = (await import("ghostty-web")) as typeof import("ghostty-web") & {
      __instances: FakeTerminal[];
    };
    const element = {
      getAttribute: () => "Shell",
      setAttribute: () => undefined,
    } as unknown as HTMLElement;
    const adapter = terminalAdapterForPane("pane-1");

    syncTerminalThemeForPreference("dark");
    await adapter.open(element, {
      label: "Shell",
      onInput: () => undefined,
      onResize: () => undefined,
    });

    expect(ghosttyWeb.__instances).toHaveLength(1);
    expect(ghosttyWeb.__instances[0]?.options.theme.background).toBe("#111111");

    syncTerminalThemeForPreference("light");

    expect(ghosttyWeb.__instances).toHaveLength(1);
    expect(ghosttyWeb.__instances[0]?.disposed).toBe(false);
    expect(ghosttyWeb.__instances[0]?.options.theme.background).toBe("#ffffff");
  });
});
