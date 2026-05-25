<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";

  const appState = getContext<AppState>(appStateKey);
  let path = $state("");

  async function addRepository(): Promise<void> {
    await appState.addRepository(path);
    if (!appState.errorMessage) {
      path = "";
    }
  }
</script>

<section>
  <div class="heading">
    <div>
      <h2>Repositories</h2>
      <p>{appState.repositories.length} registered</p>
    </div>
    <span class={`connection ${appState.connection}`}>{appState.connection}</span>
  </div>

  <form
    onsubmit={(event) => {
      event.preventDefault();
      void addRepository();
    }}
  >
    <input bind:value={path} aria-label="Repository path" placeholder="/path/to/repository" />
    <Button label="+" title="Add Repository" disabled={appState.repoBusy || !path.trim()} onclick={addRepository} />
  </form>

  <div class="repos">
    {#each appState.repositories as repository (repository.id)}
      <article>
        <span class="swatch" style={`--repo-color: ${repository.color}`}></span>
        <div class="details">
          <h3>{repository.displayName}</h3>
          <p>{repository.path}</p>
          <small>{appState.worktreesByRepo.get(repository.id)?.length ?? 0} worktrees</small>
        </div>
        <Button
          label="×"
          title={`Remove ${repository.displayName}`}
          disabled={appState.repoBusy}
          onclick={() => appState.removeRepository(repository.id)}
        />
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
  article {
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
    grid-template-columns: minmax(12rem, 1fr) auto;
    gap: 0.5rem;
  }

  input {
    min-height: 2rem;
    padding: 0 0.65rem;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    color: CanvasText;
  }

  .repos {
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

  .swatch {
    width: 0.75rem;
    align-self: stretch;
    border-radius: 999px;
    background: var(--repo-color);
  }

  .details {
    display: grid;
    flex: 1;
    min-width: 0;
    gap: 0.1rem;
  }

  .details p {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .connection {
    padding: 0.2rem 0.5rem;
    border-radius: 999px;
    background: color-mix(in srgb, CanvasText 10%, Canvas);
    font-size: 0.78rem;
  }
</style>
