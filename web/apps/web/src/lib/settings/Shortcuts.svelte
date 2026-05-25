<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import type { ActionId, ShortcutSettings } from "$lib/state/types";

  const appState = getContext<AppState>(appStateKey);
  const shortcutRows: Array<{ action: ActionId; label: string }> = [
    { action: "palette.open", label: "Open palette" },
    { action: "palette.close", label: "Close palette" },
    { action: "pane.new", label: "New pane" },
    { action: "pane.close", label: "Close pane" },
    { action: "worktree.previous", label: "Previous worktree" },
    { action: "worktree.next", label: "Next worktree" },
    { action: "tab.previous", label: "Previous tab" },
    { action: "tab.next", label: "Next tab" },
  ];
  let local = $state<ShortcutSettings>({ ...appState.settings.shortcuts });

  $effect(() => {
    local = { ...appState.settings.shortcuts };
  });

  async function save(): Promise<void> {
    await appState.updateSettings({ shortcuts: local });
  }
</script>

<section>
  <div class="heading">
    <div>
      <h2>Shortcuts</h2>
      <p>{shortcutRows.length} keyboard commands</p>
    </div>
    <Button label="✓" title="Save Shortcut Settings" onclick={save} />
  </div>

  <div class="rows">
    {#each shortcutRows as row (row.action)}
      <label>
        <span>{row.label}</span>
        <input bind:value={local[row.action]} aria-label={`${row.label} shortcut`} />
      </label>
    {/each}
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
  span {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  .rows {
    display: grid;
    grid-template-columns: repeat(2, minmax(16rem, 1fr));
    gap: 0.5rem 0.75rem;
  }

  label {
    display: grid;
    grid-template-columns: minmax(9rem, 1fr) minmax(10rem, 0.9fr);
    align-items: center;
    gap: 0.75rem;
  }

  input {
    min-height: 2rem;
    padding: 0 0.65rem;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    color: CanvasText;
    font: inherit;
  }
</style>
