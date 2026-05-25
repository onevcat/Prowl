<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import Appearance from "./Appearance.svelte";
  import RepoSettings from "./RepoSettings.svelte";

  const appState = getContext<AppState>(appStateKey);
</script>

<main class="settings">
  <header>
    <div>
      <h1>Settings</h1>
      <p>Daemon-backed workspace configuration</p>
    </div>
    <Button label="←" title="Back to Shelf" onclick={() => appState.setView("shelf")} />
  </header>

  {#if appState.errorMessage}
    <p class="error">{appState.errorMessage}</p>
  {/if}

  <RepoSettings />
  <Appearance />
</main>

<style>
  .settings {
    display: grid;
    grid-template-rows: auto auto auto 1fr;
    gap: 1rem;
    width: 100vw;
    min-height: 100vh;
    padding: 1rem;
    background: color-mix(in srgb, CanvasText 4%, Canvas);
  }

  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding-bottom: 0.75rem;
    border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
  }

  h1,
  p {
    margin: 0;
  }

  h1 {
    font-size: 1.1rem;
  }

  p {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  .error {
    padding: 0.5rem 0.65rem;
    border: 1px solid color-mix(in srgb, #ff3b30 45%, Canvas);
    border-radius: 6px;
    background: color-mix(in srgb, #ff3b30 12%, Canvas);
    color: CanvasText;
  }
</style>
