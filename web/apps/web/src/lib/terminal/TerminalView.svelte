<script lang="ts">
  import { onDestroy } from "svelte";
  import { terminalAdapterForPane } from "./GhosttyAdapter";

  type Props = {
    paneId: string;
    title: string;
    output: string;
    focused: boolean;
    buffering?: boolean;
    renderTerminal?: boolean;
    onInput?: (text: string) => void;
    onResize?: (cols: number, rows: number) => void;
    onTitleChange?: (title: string) => void;
  };

  let {
    paneId,
    title,
    output,
    focused,
    buffering = false,
    renderTerminal = true,
    onInput,
    onResize,
    onTitleChange,
  }: Props = $props();
  let element = $state<HTMLElement>();
  let status = $state<"loading" | "ready" | "failed">("loading");
  let openGeneration = 0;
  const adapter = $derived(terminalAdapterForPane(paneId));

  $effect(() => {
    adapter.syncOutput(output);
  });

  $effect(() => {
    if (!element || !renderTerminal) {
      return;
    }
    const generation = ++openGeneration;
    status = "loading";
    adapter
      .open(element, {
        label: title,
        onInput: (text) => onInput?.(text),
        onResize: (cols, rows) => onResize?.(cols, rows),
        onTitleChange: (nextTitle) => onTitleChange?.(nextTitle),
      })
      .then(() => {
        if (generation === openGeneration) {
          status = "ready";
          if (focused) {
            adapter.focus();
          }
        }
      })
      .catch(() => {
        if (generation === openGeneration) {
          status = "failed";
        }
      });
    return () => {
      openGeneration += 1;
      adapter.detach();
    };
  });

  $effect(() => {
    if (focused) {
      adapter.focus();
    }
  });

  onDestroy(() => {
    openGeneration += 1;
    adapter.detach();
  });
</script>

<div
  bind:this={element}
  class:focused
  class:render-suspended={!renderTerminal}
  class="terminal"
  role="application"
  aria-label={title}
>
  {#if !renderTerminal}
    <div class="placeholder">Renderer parked</div>
  {:else if status === "loading"}
    <div class="placeholder">Starting terminal</div>
  {:else if status === "failed"}
    <div class="placeholder">Terminal failed to initialize</div>
  {/if}
  <pre class="screen-reader-output">{output}</pre>
  {#if buffering}
    <div class="buffering" role="status">buffering...</div>
  {/if}
</div>

<style>
  .terminal {
    position: relative;
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

  .terminal :global(canvas) {
    width: 100%;
    height: 100%;
  }

  .placeholder {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    padding: 0.75rem;
    color: color-mix(in srgb, CanvasText 58%, transparent);
    font-size: 0.82rem;
  }

  .screen-reader-output {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: pre-wrap;
  }

  .render-suspended {
    background: color-mix(in srgb, CanvasText 8%, Canvas);
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
