<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";

  const appState = getContext<AppState>(appStateKey);
  let path = $state("");
  let branchByRepo = $state<Record<string, string>>({});
  let directoryByRepo = $state<Record<string, string>>({});

  async function addRepository(): Promise<void> {
    await appState.addRepository(path);
    if (!appState.errorMessage) {
      path = "";
    }
  }

  async function createWorktree(repoId: string): Promise<void> {
    await appState.createWorktree(repoId, branchByRepo[repoId] ?? "", directoryByRepo[repoId]);
    if (!appState.errorMessage) {
      branchByRepo = { ...branchByRepo, [repoId]: "" };
      directoryByRepo = { ...directoryByRepo, [repoId]: "" };
    }
  }
</script>

<section id="settings-repositories">
  <div class="heading">
    <div>
      <h2>Repositories</h2>
      <p>{appState.repositories.length} registered</p>
      {#if appState.latestArchiveProgress}
        <small class="archive-progress">{appState.latestArchiveProgress.message}</small>
      {/if}
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
      <div class="worktrees">
        {#each appState.worktreesByRepo.get(repository.id) ?? [] as worktree (worktree.id)}
          {@const archiveProgress = appState.archiveProgressByWorktree[worktree.id]}
          <div class="worktree-row">
            <div>
              <strong>{worktree.name}</strong>
              <p>{worktree.branch} · {worktree.path}</p>
              {#if archiveProgress}
                <small class="archive-progress">{archiveProgress.message}</small>
              {/if}
            </div>
            <Button
              label="×"
              title={`Archive ${worktree.name}`}
              disabled={appState.repoBusy}
              onclick={() => appState.archiveWorktree(worktree.id)}
            />
          </div>
        {/each}
        <form
          class="worktree-form"
          onsubmit={(event) => {
            event.preventDefault();
            void createWorktree(repository.id);
          }}
        >
          <input bind:value={branchByRepo[repository.id]} aria-label={`${repository.displayName} branch`} placeholder="branch" />
          <input
            bind:value={directoryByRepo[repository.id]}
            aria-label={`${repository.displayName} worktree directory`}
            placeholder="directory"
          />
          <Button
            label="+"
            title={`Create Worktree for ${repository.displayName}`}
            disabled={appState.repoBusy || !(branchByRepo[repository.id] ?? "").trim()}
            onclick={() => createWorktree(repository.id)}
          />
        </form>
      </div>
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

  .archive-progress {
    display: block;
    margin-top: 0.15rem;
    color: color-mix(in srgb, Highlight 76%, CanvasText);
  }

  form {
    display: grid;
    grid-template-columns: minmax(12rem, 1fr) auto;
    gap: 0.5rem;
  }

  .worktree-form {
    grid-template-columns: minmax(8rem, 0.7fr) minmax(10rem, 1fr) auto;
    padding-left: 1.5rem;
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

  .worktrees {
    display: grid;
    gap: 0.35rem;
    margin-top: -0.35rem;
  }

  .worktree-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    min-height: 2.75rem;
    padding: 0.45rem 0.65rem 0.45rem 1.5rem;
    border-left: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
    color: CanvasText;
  }

  strong {
    display: block;
    font-size: 0.9rem;
  }

  .worktree-row p {
    overflow: hidden;
    max-width: 52rem;
    text-overflow: ellipsis;
    white-space: nowrap;
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
