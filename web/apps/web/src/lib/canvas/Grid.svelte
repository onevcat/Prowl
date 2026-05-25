<script lang="ts">
  import type { Pane } from "$lib/state/Pane";
  import type { TaskStatus } from "$lib/state/types";
  import CanvasPane from "./CanvasPane.svelte";

  type Props = {
    panes: Pane[];
    selectedPaneId: string | null;
    selectPane: (paneId: string) => void;
    sendInput: (paneId: string, text: string) => void;
    resizePane: (paneId: string, cols: number, rows: number) => void;
    updateStatus: (paneId: string, status: TaskStatus) => void;
    zoomPane: (paneId: string) => void;
  };

  let { panes, selectedPaneId, selectPane, sendInput, resizePane, updateStatus, zoomPane }: Props = $props();
</script>

<div class="grid">
  {#each panes as pane (pane.id)}
    <CanvasPane
      {pane}
      focused={pane.id === selectedPaneId}
      onclick={() => selectPane(pane.id)}
      onInput={(text) => sendInput(pane.id, text)}
      onResize={(cols, rows) => resizePane(pane.id, cols, rows)}
      onStatus={(status) => updateStatus(pane.id, status)}
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
