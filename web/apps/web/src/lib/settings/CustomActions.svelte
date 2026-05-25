<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import type { CustomAction } from "@prowl/protocol";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";

  const appState = getContext<AppState>(appStateKey);
  let editingId = $state<string | null>(null);
  let name = $state("");
  let command = $state("");
  let repoId = $state("");
  let shortcut = $state("");
  let icon = $state("");
  let outputMode = $state<CustomAction["outputMode"]>("currentPane");

  function edit(action: CustomAction): void {
    editingId = action.id;
    name = action.name;
    command = action.command;
    repoId = action.repoId ?? "";
    shortcut = action.shortcut ?? "";
    icon = action.icon ?? "";
    outputMode = action.outputMode;
  }

  function reset(): void {
    editingId = null;
    name = "";
    command = "";
    repoId = "";
    shortcut = "";
    icon = "";
    outputMode = "currentPane";
  }

  async function save(): Promise<void> {
    await appState.saveCustomAction({
      id: editingId ?? undefined,
      repoId: repoId || null,
      name,
      command,
      shortcut: shortcut || undefined,
      icon: icon || undefined,
      outputMode,
      ordering: editingId ? (appState.customActions.find((action) => action.id === editingId)?.ordering ?? 0) : Date.now(),
    });
    if (!appState.errorMessage) {
      reset();
    }
  }
</script>

<section id="settings-custom-actions">
  <div class="heading">
    <div>
      <h2>Custom Actions</h2>
      <p>{appState.customActions.length} configured</p>
    </div>
  </div>

  <form
    onsubmit={(event) => {
      event.preventDefault();
      void save();
    }}
  >
    <input bind:value={name} aria-label="Action name" placeholder="Name" />
    <input bind:value={command} aria-label="Action command" placeholder="Command" />
    <select bind:value={repoId} aria-label="Action repository">
      <option value="">Global</option>
      {#each appState.repositories as repository (repository.id)}
        <option value={repository.id}>{repository.displayName}</option>
      {/each}
    </select>
    <input bind:value={shortcut} aria-label="Action shortcut" placeholder="Shortcut" />
    <input bind:value={icon} aria-label="Action icon" placeholder="Icon" />
    <select bind:value={outputMode} aria-label="Action output">
      <option value="currentPane">Current pane</option>
      <option value="newPane">New pane</option>
    </select>
    <Button label={editingId ? "✓" : "+"} title={editingId ? "Save Custom Action" : "Add Custom Action"} disabled={!name.trim() || !command.trim() || appState.repoBusy} onclick={save} />
    {#if editingId}
      <Button label="×" title="Cancel Custom Action Edit" onclick={reset} />
    {/if}
  </form>

  <div class="actions">
    {#each appState.customActions as action (action.id)}
      <article>
        <div>
          <h3>{action.name}</h3>
          <p>{action.command}</p>
          <small>{action.outputMode === "newPane" ? "New pane" : "Current pane"} · {action.repoId ? (appState.repositories.find((repository) => repository.id === action.repoId)?.displayName ?? "Repository") : "Global"}</small>
        </div>
        <div class="buttons">
          <Button label="▶" title={`Run ${action.name}`} disabled={!appState.selectedPaneId} onclick={() => appState.runCustomAction(action.id)} />
          <Button label="✎" title={`Edit ${action.name}`} onclick={() => edit(action)} />
          <Button label="×" title={`Delete ${action.name}`} disabled={appState.repoBusy} onclick={() => appState.deleteCustomAction(action.id)} />
        </div>
      </article>
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

  .heading,
  article,
  .buttons {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
  }

  h2,
  h3,
  p {
    margin: 0;
  }

  h2 {
    font-size: 1rem;
  }

  h3 {
    font-size: 0.95rem;
  }

  p,
  small {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  form {
    display: grid;
    grid-template-columns:
      minmax(8rem, 0.8fr) minmax(12rem, 1.3fr) minmax(8rem, 0.7fr) minmax(7rem, 0.6fr)
      minmax(5rem, 0.4fr) minmax(8rem, 0.7fr) auto auto;
    gap: 0.5rem;
  }

  input,
  select {
    min-height: 2rem;
    padding: 0 0.65rem;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    color: CanvasText;
  }

  .actions {
    display: grid;
    gap: 0.5rem;
  }

  article {
    min-height: 3.25rem;
    padding: 0.65rem;
    border: 1px solid color-mix(in srgb, CanvasText 10%, transparent);
    border-radius: 6px;
    background: color-mix(in srgb, CanvasText 3%, Canvas);
  }

  article > div:first-child {
    min-width: 0;
  }

  article p {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
