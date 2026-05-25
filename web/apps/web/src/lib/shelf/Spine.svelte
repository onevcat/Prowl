<script lang="ts">
  import type { Worktree } from "$lib/state/types";

  type Props = {
    worktree: Worktree;
    color: string;
    selected: boolean;
    onclick: () => void;
    ondragstart: () => void;
    ondragover: () => void;
    ondrop: () => void;
    ondragend: () => void;
  };

  let { worktree, color, selected, onclick, ondragstart, ondragover, ondrop, ondragend }: Props = $props();
</script>

<button
  class:selected
  draggable="true"
  style={`--repo-color: ${color}`}
  type="button"
  {onclick}
  title={`Select ${worktree.name}`}
  ondragstart={(event) => {
    event.dataTransfer?.setData("text/plain", worktree.id);
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
  <span class={`status ${worktree.taskStatus}`}></span>
  <span class="name">{worktree.name}</span>
  {#if worktree.unreadCount > 0}
    <span class="count">{worktree.unreadCount}</span>
  {/if}
</button>

<style>
  button {
    display: grid;
    grid-template-columns: 0.4rem minmax(0, 1fr) auto;
    gap: 0.55rem;
    align-items: center;
    width: 100%;
    min-height: 2.5rem;
    padding: 0 0.6rem;
    border: 0;
    border-left: 0.25rem solid var(--repo-color);
    border-radius: 0;
    background: transparent;
    color: CanvasText;
    text-align: left;
  }

  button:hover,
  button.selected {
    background: color-mix(in srgb, var(--repo-color) 18%, Canvas);
  }

  .name {
    overflow: hidden;
    font-weight: 600;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .status,
  .count {
    width: 0.5rem;
    height: 0.5rem;
    border-radius: 999px;
    background: color-mix(in srgb, CanvasText 35%, Canvas);
  }

  .status.running {
    background: #34c759;
  }

  .status.done {
    background: #0a84ff;
  }

  .status.failed {
    background: #ff3b30;
  }

  .count {
    display: inline-grid;
    place-items: center;
    width: 1.15rem;
    height: 1.15rem;
    background: #ff9f0a;
    color: #111;
    font-size: 0.7rem;
    font-weight: 700;
  }
</style>
