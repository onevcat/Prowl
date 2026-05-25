<script lang="ts">
  import type { Pane } from "$lib/state/Pane.svelte";
  import TerminalView from "$lib/terminal/TerminalView.svelte";

  type Props = {
    pane: Pane;
    focused: boolean;
    renderTerminal: boolean;
    buffering: boolean;
    onclick: () => void;
    onInput: (text: string) => void;
    onParsedOutput: (text: string) => void;
    onResize: (cols: number, rows: number) => void;
    ondblclick: () => void;
  };

  let { pane, focused, renderTerminal, buffering, onclick, onInput, onParsedOutput, onResize, ondblclick }: Props =
    $props();

  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

  function relativeTime(timestamp: number): string {
    const seconds = Math.round((timestamp - Date.now()) / 1000);
    if (Math.abs(seconds) < 60) {
      return formatter.format(seconds, "second");
    }
    return formatter.format(Math.round(seconds / 60), "minute");
  }
</script>

<div
  class:focused
  role="button"
  tabindex="0"
  onclick={onclick}
  ondblclick={ondblclick}
  onkeydown={(event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      onclick();
    }
  }}
>
  <header>
    <strong>{pane.title}</strong>
    <span>{relativeTime(pane.updatedAt)}</span>
    <span class={`badge ${pane.taskStatus}`}>{pane.taskStatus}</span>
  </header>
  {#if renderTerminal}
    <TerminalView
      paneId={pane.id}
      title={pane.title}
      output={pane.output}
      {focused}
      {buffering}
      {onInput}
      {onParsedOutput}
      {onResize}
    />
  {:else}
    <section class="renderer-idle" aria-label={`${pane.title} renderer idle`}>
      <strong>{pane.title}</strong>
      <p>{pane.lastOutputLine || "Renderer paused"}</p>
    </section>
  {/if}
</div>

<style>
  div {
    display: grid;
    grid-template-rows: 2rem minmax(0, 1fr);
    min-height: 14rem;
    overflow: hidden;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
  }

  div.focused {
    border-color: AccentColor;
  }

  header {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto auto;
    align-items: center;
    gap: 0.5rem;
    min-width: 0;
    padding: 0 0.55rem;
    border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
  }

  .renderer-idle {
    display: grid;
    align-content: center;
    gap: 0.35rem;
    min-height: 12rem;
    padding: 1rem;
    border: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
    border-radius: 6px;
    background: color-mix(in srgb, CanvasText 5%, Canvas);
  }

  .renderer-idle strong,
  .renderer-idle p {
    overflow: hidden;
    margin: 0;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .renderer-idle p {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  strong {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  span {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
    font-size: 0.78rem;
  }

  .badge {
    padding: 0.1rem 0.35rem;
    border-radius: 999px;
    background: color-mix(in srgb, CanvasText 10%, Canvas);
    color: CanvasText;
  }

  .badge.running {
    background: color-mix(in srgb, #34c759 25%, Canvas);
  }
</style>
