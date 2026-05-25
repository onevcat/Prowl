<script lang="ts">
  import type { Pane } from "$lib/state/Pane";
  import CanvasPane from "./CanvasPane.svelte";

  type Props = {
    panes: Pane[];
    selectedPaneId: string | null;
    selectPane: (paneId: string) => void;
    zoomPane: (paneId: string) => void;
  };

  let { panes, selectedPaneId, selectPane, zoomPane }: Props = $props();
</script>

<div class="grid">
  {#each panes as pane (pane.id)}
    <CanvasPane
      {pane}
      focused={pane.id === selectedPaneId}
      onclick={() => selectPane(pane.id)}
      ondblclick={() => zoomPane(pane.id)}
    />
  {/each}
</div>

<style>
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(20rem, 1fr));
    gap: 0.75rem;
    min-height: 0;
    overflow: auto;
    padding: 0.75rem;
  }
</style>
