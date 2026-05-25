<script lang="ts">
  import type { Pane } from "$lib/state/Pane.svelte";
  import CanvasPane from "./CanvasPane.svelte";

  type Props = {
    panes: Pane[];
    renderablePaneIds: Set<string>;
    selectedPaneId: string | null;
    buffering: boolean;
    selectPane: (paneId: string) => void;
    sendInput: (paneId: string, text: string) => void;
    onParsedOutput: (paneId: string, text: string) => void;
    resizePane: (paneId: string, cols: number, rows: number) => void;
    zoomPane: (paneId: string) => void;
  };

  let {
    panes,
    renderablePaneIds,
    selectedPaneId,
    buffering,
    selectPane,
    sendInput,
    onParsedOutput,
    resizePane,
    zoomPane,
  }: Props = $props();
</script>

<div class="grid">
  {#each panes as pane (pane.id)}
    <CanvasPane
      {pane}
      focused={pane.id === selectedPaneId}
      renderTerminal={renderablePaneIds.has(pane.id)}
      {buffering}
      onclick={() => selectPane(pane.id)}
      onInput={(text) => sendInput(pane.id, text)}
      onParsedOutput={(text) => onParsedOutput(pane.id, text)}
      onResize={(cols, rows) => resizePane(pane.id, cols, rows)}
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
