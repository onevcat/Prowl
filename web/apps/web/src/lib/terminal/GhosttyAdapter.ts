type Disposable = { dispose(): void };
type GhosttyWebModule = typeof import("ghostty-web");
type GhosttyTerminal = InstanceType<GhosttyWebModule["Terminal"]>;
type GhosttyFitAddon = InstanceType<GhosttyWebModule["FitAddon"]>;
type TerminalTheme = {
  background: string;
  foreground: string;
  cursor: string;
  selectionBackground: string;
};

export type TerminalAdapter = {
  open(element: HTMLElement, callbacks: TerminalAdapterCallbacks): Promise<void>;
  syncOutput(text: string): void;
  resize(cols: number, rows: number): void;
  focus(): void;
  detach(): void;
  dispose(): void;
};

export type TerminalAdapterCallbacks = {
  label: string;
  onInput: (text: string) => void;
  onParsedOutput?: (text: string) => void;
  onResize: (cols: number, rows: number) => void;
  onTitleChange?: (title: string) => void;
};

const darkTerminalTheme: TerminalTheme = {
  background: "#111111",
  foreground: "#f5f5f5",
  cursor: "#f5f5f5",
  selectionBackground: "#3b82f6",
};
const lightTerminalTheme: TerminalTheme = {
  background: "#ffffff",
  foreground: "#1f1f1f",
  cursor: "#1f1f1f",
  selectionBackground: "#0a84ff",
};

let ghosttyInitPromise: Promise<void> | null = null;
let ghosttyModulePromise: Promise<GhosttyWebModule> | null = null;
let currentTerminalTheme = darkTerminalTheme;
const adapters = new Map<string, GhosttyTerminalAdapter>();

export function terminalAdapterForPane(paneId: string): GhosttyTerminalAdapter {
  const existing = adapters.get(paneId);
  if (existing) {
    return existing;
  }
  const adapter = new GhosttyTerminalAdapter();
  adapters.set(paneId, adapter);
  return adapter;
}

export function disposeTerminalAdapterForPane(paneId: string): void {
  adapters.get(paneId)?.dispose();
  adapters.delete(paneId);
}

export function resetTerminalAdaptersForTests(): void {
  for (const adapter of adapters.values()) {
    adapter.dispose();
  }
  adapters.clear();
  currentTerminalTheme = darkTerminalTheme;
}

export function syncTerminalThemeForPreference(
  preference: "system" | "light" | "dark",
  prefersDark = systemPrefersDark(),
): void {
  currentTerminalTheme = terminalThemeForPreference(preference, prefersDark);
  for (const adapter of adapters.values()) {
    adapter.applyTheme(currentTerminalTheme);
  }
}

export function terminalThemeForPreference(
  preference: "system" | "light" | "dark",
  prefersDark = systemPrefersDark(),
): TerminalTheme {
  if (preference === "light") {
    return lightTerminalTheme;
  }
  if (preference === "dark") {
    return darkTerminalTheme;
  }
  return prefersDark ? darkTerminalTheme : lightTerminalTheme;
}

export class GhosttyTerminalAdapter implements TerminalAdapter {
  #term: GhosttyTerminal | null = null;
  #fitAddon: GhosttyFitAddon | null = null;
  #subscriptions: Disposable[] = [];
  #targetText = "";
  #renderedText = "";
  #callbacks: TerminalAdapterCallbacks | null = null;
  #openGeneration = 0;
  #theme = currentTerminalTheme;

  async open(element: HTMLElement, callbacks: TerminalAdapterCallbacks): Promise<void> {
    this.#callbacks = callbacks;
    const generation = ++this.#openGeneration;
    await initializeGhostty();
    if (generation !== this.#openGeneration) {
      return;
    }
    if (!this.#term) {
      this.#createTerminal(await loadGhosttyWeb());
    }
    const term = this.#term;
    if (!term) {
      return;
    }
    if (term.element !== element) {
      if (term.element) {
        term.dispose();
        this.#clearRuntime();
        this.#createTerminal(await loadGhosttyWeb());
      }
      const accessibleName = this.#callbacks?.label || element.getAttribute("aria-label") || "Terminal";
      this.#term?.open(element);
      element.setAttribute("role", "textbox");
      element.setAttribute("aria-label", accessibleName);
      this.#fitAddon?.observeResize();
      this.#fitAddon?.fit();
      this.#renderedText = "";
      this.#writeTargetText();
    }
    this.focus();
  }

  syncOutput(text: string): void {
    this.#targetText = text;
    this.#writeTargetText();
  }

  resize(cols: number, rows: number): void {
    this.#term?.resize(cols, rows);
  }

  focus(): void {
    this.#term?.focus();
  }

  applyTheme(theme: TerminalTheme): void {
    this.#theme = theme;
    const term = this.#term;
    if (term && "options" in term) {
      (term as GhosttyTerminal & { options: { theme?: TerminalTheme } }).options.theme = theme;
    }
  }

  detach(): void {
    this.#openGeneration += 1;
  }

  dispose(): void {
    this.#openGeneration += 1;
    this.#term?.dispose();
    this.#clearRuntime();
    this.#targetText = "";
    this.#renderedText = "";
    this.#callbacks = null;
  }

  #writeTargetText(): void {
    const term = this.#term;
    if (!term) {
      return;
    }
    const text = this.#targetText;
    if (text === this.#renderedText) {
      return;
    }
    if (text.startsWith(this.#renderedText)) {
      const chunk = text.slice(this.#renderedText.length);
      term.write(chunk);
      this.#callbacks?.onParsedOutput?.(chunk);
    } else {
      term.reset();
      term.write(text);
      this.#callbacks?.onParsedOutput?.(text);
    }
    this.#renderedText = text;
  }

  #createTerminal(ghosttyWeb: GhosttyWebModule): void {
    const term = new ghosttyWeb.Terminal({
      cols: 120,
      rows: 32,
      cursorBlink: true,
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace',
      fontSize: 13,
      scrollback: 4096,
      theme: this.#theme,
    });
    const fitAddon = new ghosttyWeb.FitAddon();
    term.loadAddon(fitAddon);
    this.#subscriptions = [
      term.onData((data) => this.#callbacks?.onInput(data)),
      term.onResize((size) => this.#callbacks?.onResize(size.cols, size.rows)),
      term.onTitleChange((title) => this.#callbacks?.onTitleChange?.(title)),
    ];
    this.#term = term;
    this.#fitAddon = fitAddon;
  }

  #clearRuntime(): void {
    for (const subscription of this.#subscriptions) {
      subscription.dispose();
    }
    this.#subscriptions = [];
    this.#fitAddon = null;
    this.#term = null;
  }
}

function initializeGhostty(): Promise<void> {
  ghosttyInitPromise ??= loadGhosttyWeb().then((ghosttyWeb) => ghosttyWeb.init());
  return ghosttyInitPromise;
}

function loadGhosttyWeb(): Promise<GhosttyWebModule> {
  ghosttyModulePromise ??= import("ghostty-web");
  return ghosttyModulePromise;
}

function systemPrefersDark(): boolean {
  return typeof window !== "undefined" && window.matchMedia?.("(prefers-color-scheme: dark)").matches === true;
}
