<script lang="ts">
  import Canvas from "$lib/canvas/Canvas.svelte";
  import DiffView from "$lib/diff/DiffView.svelte";
  import Palette from "$lib/palette/Palette.svelte";
  import Settings from "$lib/settings/Settings.svelte";
  import Shelf from "$lib/shelf/Shelf.svelte";
  import { appStateKey, createAppState } from "$lib/state/AppState.svelte";
  import { setContext } from "svelte";

  const appState = createAppState();
  setContext(appStateKey, appState);
</script>

<svelte:head>
  <title>Prowl Web</title>
</svelte:head>

<svelte:window
  onkeydown={(event) => {
    appState.handleKeydown(event);
  }}
/>

{#if appState.view === "canvas"}
  <Canvas />
{:else if appState.view === "settings"}
  <Settings />
{:else if appState.view === "diff"}
  <DiffView />
{:else}
  <Shelf />
{/if}

<Palette />
