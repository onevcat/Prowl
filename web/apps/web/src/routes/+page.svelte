<script lang="ts">
  import AuthGate from "$lib/auth/AuthGate.svelte";
  import Canvas from "$lib/canvas/Canvas.svelte";
  import DiffView from "$lib/diff/DiffView.svelte";
  import Palette from "$lib/palette/Palette.svelte";
  import PerformanceHUD from "$lib/performance/PerformanceHUD.svelte";
  import Settings from "$lib/settings/Settings.svelte";
  import Shelf from "$lib/shelf/Shelf.svelte";
  import { appStateKey, createAppState } from "$lib/state/AppState.svelte";
  import { setContext } from "svelte";

  const appState = createAppState();
  setContext(appStateKey, appState);

  $effect(() => {
    appState.view;
    appState.selectedWorktreeId;
    appState.selectedPaneId;
    appState.panes.size;
    appState.syncRenderedPanes();
  });
</script>

<svelte:head>
  <title>Prowl Web</title>
</svelte:head>

<svelte:window
  onkeydown={(event) => {
    appState.handleKeydown(event);
  }}
/>

{#if appState.needsAuthentication}
  <AuthGate {appState} />
{:else if appState.view === "canvas"}
  <Canvas />
{:else if appState.view === "settings"}
  <Settings />
{:else if appState.view === "diff"}
  <DiffView />
{:else}
  <Shelf />
{/if}

<Palette />
<PerformanceHUD />
