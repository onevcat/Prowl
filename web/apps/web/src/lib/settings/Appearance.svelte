<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import type { AppearanceSettings } from "$lib/state/types";

  const appState = getContext<AppState>(appStateKey);
  let local = $state<AppearanceSettings>({ ...appState.settings.appearance });

  $effect(() => {
    local = { ...appState.settings.appearance };
  });

  async function save(): Promise<void> {
    await appState.updateSettings({ appearance: local });
  }
</script>

<section id="settings-appearance">
  <div class="heading">
    <div>
      <h2>Appearance</h2>
      <p>Theme and terminal presentation</p>
    </div>
    <Button label="✓" title="Save Appearance Settings" onclick={save} />
  </div>

  <div class="grid">
    <label>
      Theme
      <select bind:value={local.theme}>
        <option value="system">System</option>
        <option value="light">Light</option>
        <option value="dark">Dark</option>
      </select>
    </label>
    <label>
      Terminal density
      <select bind:value={local.terminalDensity}>
        <option value="comfortable">Comfortable</option>
        <option value="compact">Compact</option>
      </select>
    </label>
    <label class="check">
      <input type="checkbox" bind:checked={local.showUnreadBadges} />
      Show unread badges
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

  select {
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
