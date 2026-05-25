<script lang="ts">
  import { detectAgentTaskStatus } from "./detectAgent";

  type Props = {
    title: string;
    lastOutputLine: string;
    focused: boolean;
    onInput?: (text: string) => void;
    onResize?: (cols: number, rows: number) => void;
    onStatus?: (status: "idle" | "running" | "done" | "failed") => void;
  };

  let { title, lastOutputLine, focused, onInput, onResize, onStatus }: Props = $props();
  let buffer = $state("");
  let element = $state<HTMLElement>();

  $effect(() => {
    buffer = lastOutputLine;
  });

  $effect(() => {
    if (!element || !onResize) {
      return;
    }
    const terminal = element;
    const observer = new ResizeObserver(([entry]) => {
      if (!entry) {
        return;
      }
      const style = getComputedStyle(terminal);
      const fontSize = Number.parseFloat(style.fontSize) || 13;
      const cols = Math.max(1, Math.floor(entry.contentRect.width / (fontSize * 0.62)));
      const rows = Math.max(1, Math.floor(entry.contentRect.height / (fontSize * 1.35)));
      onResize(cols, rows);
    });
    observer.observe(terminal);
    return () => observer.disconnect();
  });

  function handleKeydown(event: KeyboardEvent): void {
    if (event.metaKey || event.ctrlKey || event.altKey) {
      return;
    }
    if (event.key.length === 1 || event.key === "Enter" || event.key === "Backspace") {
      event.preventDefault();
      const text = event.key === "Enter" ? "\n" : event.key === "Backspace" ? "\b" : event.key;
      onInput?.(text);
      onStatus?.(detectAgentTaskStatus(buffer));
    }
  }
</script>

<div
  bind:this={element}
  class:focused
  class="terminal mono"
  role="textbox"
  aria-label={title}
  tabindex="0"
  onkeydown={handleKeydown}
>
  <div class="screen">
    {buffer || "Waiting for daemon-backed terminal"}
  </div>
</div>

<style>
  .terminal {
    display: grid;
    width: 100%;
    height: 100%;
    min-height: 12rem;
    overflow: hidden;
    border: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
    border-radius: 6px;
    background: #111;
    color: #f5f5f5;
    outline: none;
  }

  .terminal.focused {
    border-color: AccentColor;
    box-shadow: inset 0 0 0 1px AccentColor;
  }

  .screen {
    padding: var(--terminal-padding, 0.75rem);
    white-space: pre-wrap;
  }
</style>
