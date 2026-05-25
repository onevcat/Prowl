<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import { encodeBroadcastKey } from "./broadcast";
  import Grid from "./Grid.svelte";

  const appState = getContext<AppState>(appStateKey);
  let broadcast = $state("");

  function sendBroadcast(): void {
    if (!broadcast) {
      return;
    }
    appState.sendInputToVisiblePanes(`${broadcast}\n`);
    broadcast = "";
  }

  function handleBroadcastKeydown(event: KeyboardEvent): void {
    const input = encodeBroadcastKey(event);
    if (!input) {
      return;
    }
    event.preventDefault();
    appState.sendInputToVisiblePanes(input);
    broadcast = "";
  }

  function handleBroadcastPaste(event: ClipboardEvent): void {
    const text = event.clipboardData?.getData("text");
    if (!text) {
      return;
    }
    event.preventDefault();
    appState.sendInputToVisiblePanes(text);
    broadcast = "";
  }
</script>

<main class="canvas">
  <header>
    <Button label="←" title="Show Shelf" onclick={() => appState.setView("shelf")} />
    <input
      bind:value={broadcast}
      aria-label="Broadcast input"
      placeholder="Broadcast to visible panes"
      onkeydown={handleBroadcastKeydown}
      onpaste={handleBroadcastPaste}
    />
    <Button label="↵" title="Send Broadcast" onclick={sendBroadcast} />
    <Button label="⌘K" title="Open Command Palette (Command K)" onclick={() => appState.perform("palette.open")} />
  </header>

  <Grid
    panes={appState.visiblePanes}
    renderablePaneIds={appState.renderablePaneIds}
    selectedPaneId={appState.selectedPaneId}
    buffering={appState.terminalBuffering}
    selectPane={(paneId) => appState.selectPane(paneId)}
    sendInput={(paneId, text) => appState.sendInputToPane(paneId, text)}
    onParsedOutput={(paneId, text) => appState.detectPaneStatusFromTerminal(paneId, text)}
    resizePane={(paneId, cols, rows) => appState.resizePane(paneId, cols, rows)}
    zoomPane={(paneId) => {
      appState.selectPane(paneId);
      appState.setView("shelf");
    }}
  />
</main>

<style>
  .canvas {
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    width: 100vw;
    height: 100vh;
    background: color-mix(in srgb, CanvasText 4%, Canvas);
  }

  header {
    display: grid;
    grid-template-columns: auto minmax(16rem, 1fr) auto auto;
    gap: 0.5rem;
    align-items: center;
    padding: 0.65rem;
    border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    background: Canvas;
  }

  input {
    width: 100%;
    min-height: 2rem;
    padding: 0 0.65rem;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    color: CanvasText;
  }
</style>
