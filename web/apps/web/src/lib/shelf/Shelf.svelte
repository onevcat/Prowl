<script lang="ts">
  import { Button } from "@prowl/ui";
  import TerminalView from "$lib/terminal/TerminalView.svelte";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import Spine from "./Spine.svelte";
  import TabRow from "./TabRow.svelte";

  const appState = getContext<AppState>(appStateKey);
</script>

<main class="shell">
  <aside class="sidebar" aria-label="Worktrees and tabs">
    <div class="toolbar">
      <Button label="⌘K" title="Open Command Palette (Command K)" onclick={() => (appState.paletteOpen = true)} />
      <Button label="▦" title="Show Canvas" onclick={() => appState.setView("canvas")} />
      <Button label="+" title="New Tab (Command T)" onclick={() => appState.createPane()} />
    </div>

    {#each appState.repositories as repository (repository.id)}
      <section>
        <h2>{repository.displayName}</h2>
        {#each appState.worktreesByRepo.get(repository.id) ?? [] as worktree (worktree.id)}
          <Spine
            {worktree}
            color={repository.color}
            selected={worktree.id === appState.selectedWorktreeId}
            onclick={() => appState.selectWorktree(worktree.id)}
          />
          {#if worktree.id === appState.selectedWorktreeId}
            <div class="tabs">
              {#each Array.from(appState.panes.values()).filter((pane) => pane.worktreeId === worktree.id) as pane (pane.id)}
                <TabRow {pane} selected={pane.id === appState.selectedPaneId} onclick={() => appState.selectPane(pane.id)} />
              {/each}
            </div>
          {/if}
        {/each}
      </section>
    {/each}
  </aside>

  <section class="content" aria-label="Terminal">
    <header>
      <div>
        <h1>{appState.selectedWorktree?.name ?? "No worktree"}</h1>
        <p>{appState.selectedWorktree?.branch ?? "Select a worktree"}</p>
      </div>
      <span class={`connection ${appState.connection}`}>{appState.connection}</span>
    </header>

    {#if appState.selectedPane}
      <TerminalView
        title={appState.selectedPane.title}
        lastOutputLine={appState.selectedPane.lastOutputLine}
        focused={true}
        onInput={(text) => {
          appState.selectedPane!.lastOutputLine += text;
          appState.selectedPane!.updatedAt = Date.now();
        }}
        onStatus={(status) => {
          appState.selectedPane!.taskStatus = status;
        }}
      />
    {:else}
      <div class="empty">No terminals open</div>
    {/if}
  </section>
</main>

<style>
  .shell {
    display: grid;
    grid-template-columns: 20rem minmax(0, 1fr);
    width: 100vw;
    height: 100vh;
  }

  .sidebar {
    overflow: auto;
    border-right: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    background: color-mix(in srgb, CanvasText 4%, Canvas);
  }

  .toolbar {
    position: sticky;
    top: 0;
    z-index: 2;
    display: flex;
    gap: 0.4rem;
    padding: 0.65rem;
    border-bottom: 1px solid color-mix(in srgb, CanvasText 10%, transparent);
    background: Canvas;
  }

  h2 {
    margin: 1rem 0.75rem 0.35rem;
    color: color-mix(in srgb, CanvasText 62%, Canvas);
    font-size: 0.78rem;
    font-weight: 700;
    text-transform: uppercase;
  }

  .tabs {
    display: grid;
    gap: 0.15rem;
    padding: 0.25rem 0.4rem 0.45rem 1rem;
  }

  .content {
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    gap: 0.75rem;
    min-width: 0;
    padding: 0.75rem;
  }

  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    min-height: 3rem;
  }

  h1,
  p {
    margin: 0;
  }

  h1 {
    font-size: 1.05rem;
  }

  p {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  .connection {
    padding: 0.2rem 0.5rem;
    border-radius: 999px;
    background: color-mix(in srgb, CanvasText 10%, Canvas);
    font-size: 0.78rem;
  }

  .empty {
    display: grid;
    place-items: center;
    border: 1px dashed color-mix(in srgb, CanvasText 22%, transparent);
    border-radius: 6px;
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }
</style>
