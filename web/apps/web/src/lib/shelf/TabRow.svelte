<script lang="ts">
  import type { Pane } from "$lib/state/Pane";

  type Props = {
    pane: Pane;
    selected: boolean;
    onclick: () => void;
    ondragstart: () => void;
    ondragover: () => void;
    ondrop: () => void;
    ondragend: () => void;
  };

  let { pane, selected, onclick, ondragstart, ondragover, ondrop, ondragend }: Props = $props();
</script>

<button
  class:selected
  draggable="true"
  type="button"
  {onclick}
  title={`Select ${pane.title}`}
  ondragstart={(event) => {
    event.dataTransfer?.setData("text/plain", pane.id);
    ondragstart();
  }}
  ondragover={(event) => {
    event.preventDefault();
    ondragover();
  }}
  ondrop={(event) => {
    event.preventDefault();
    ondrop();
  }}
  ondragend={ondragend}
>
  <span class={`dot ${pane.taskStatus}`}></span>
  <span class="title">{pane.title}</span>
  {#if pane.unread}
    <span class="unread" aria-label="Unread notification"></span>
  {/if}
</button>

<style>
  button {
    display: grid;
    grid-template-columns: 0.65rem minmax(0, 1fr) auto;
    align-items: center;
    gap: 0.45rem;
    width: 100%;
    min-height: 2rem;
    padding: 0 0.55rem;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: CanvasText;
    text-align: left;
  }

  button:hover,
  button.selected {
    background: color-mix(in srgb, AccentColor 18%, Canvas);
  }

  .title {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .dot,
  .unread {
    width: 0.5rem;
    height: 0.5rem;
    border-radius: 999px;
    background: color-mix(in srgb, CanvasText 36%, Canvas);
  }

  .dot.running {
    background: #34c759;
  }

  .dot.done {
    background: #0a84ff;
  }

  .dot.failed {
    background: #ff3b30;
  }

  .unread {
    background: #ff9f0a;
  }
</style>
