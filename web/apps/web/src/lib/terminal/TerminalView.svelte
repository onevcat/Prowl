<script lang="ts">
  import { encodeTerminalKey } from "./keyEncoding";

  type Props = {
    title: string;
    output: string;
    focused: boolean;
    buffering?: boolean;
    onInput?: (text: string) => void;
    onResize?: (cols: number, rows: number) => void;
  };

  let { title, output, focused, buffering = false, onInput, onResize }: Props = $props();
  let buffer = $state("");
  let element = $state<HTMLElement>();

  $effect(() => {
    buffer = output;
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
    const text = encodeTerminalKey(event);
    if (text) {
      event.preventDefault();
      onInput?.(text);
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
  {#if buffering}
    <div class="buffering" role="status">buffering...</div>
  {/if}
</div>

<style>
  .terminal {
    position: relative;
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

  .buffering {
    position: absolute;
    right: 0.5rem;
    bottom: 0.5rem;
    padding: 0.18rem 0.45rem;
    border: 1px solid color-mix(in srgb, AccentColor 45%, CanvasText);
    border-radius: 4px;
    background: color-mix(in srgb, AccentColor 22%, Canvas);
    color: CanvasText;
    font-size: 0.75rem;
  }
</style>
