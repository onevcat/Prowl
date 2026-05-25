<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import type { AdvancedSettings } from "$lib/state/types";

  const appState = getContext<AppState>(appStateKey);
  let local = $state<AdvancedSettings>({ ...appState.settings.advanced });

  $effect(() => {
    local = { ...appState.settings.advanced };
  });

  async function save(): Promise<void> {
    await appState.updateSettings({ advanced: local });
  }
</script>

<section>
  <div class="heading">
    <div>
      <h2>Advanced</h2>
      <p>Debug and daemon-facing options</p>
    </div>
    <Button label="✓" title="Save Advanced Settings" onclick={save} />
  </div>

  <div class="grid">
    <label class="check">
      <input type="checkbox" bind:checked={local.performanceHUD} />
      Performance HUD
    </label>
    <label class="check">
      <input type="checkbox" bind:checked={local.confirmDestructiveActions} />
      Confirm destructive actions
    </label>
    <label>
      Replay buffer
      <input type="number" min="16" max="1024" step="16" bind:value={local.replayBufferKiB} />
    </label>
  </div>
</section>

<style>
  section {
    display: grid;
    gap: 0.75rem;
    padding: 1rem;
    border: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    border-radius: 8px;
    background: Canvas;
  }

  .heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
  }

  h2,
  p {
    margin: 0;
  }

  h2 {
    font-size: 1rem;
  }

  p,
  label {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  .grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(10rem, 1fr));
    gap: 0.75rem;
  }

  label {
    display: grid;
    gap: 0.35rem;
    font-size: 0.85rem;
  }

  input[type="number"] {
    min-height: 2rem;
    padding: 0 0.65rem;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    color: CanvasText;
    font: inherit;
  }

  .check {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding-top: 1.35rem;
  }
</style>
