<script lang="ts">
  import { Button } from "@prowl/ui";
  import TerminalView from "$lib/terminal/TerminalView.svelte";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import Spine from "./Spine.svelte";
  import TabRow from "./TabRow.svelte";

  const appState = getContext<AppState>(appStateKey);
  let draggedWorktree = $state<{ repoId: string; worktreeId: string } | null>(null);
  let draggedPane = $state<{ worktreeId: string; paneId: string } | null>(null);
  let actionMenuOpen = $state(false);
  let worktreeMenu = $state<{ worktreeId: string; x: number; y: number } | null>(null);
  let runnableActions = $derived(appState.runnableCustomActions);

  function openWorktreeMenu(event: MouseEvent, worktreeId: string): void {
    event.preventDefault();
    appState.selectWorktree(worktreeId);
    worktreeMenu = { worktreeId, x: event.clientX, y: event.clientY };
  }

  function closeMenus(): void {
    actionMenuOpen = false;
    worktreeMenu = null;
  }
</script>

<main class="shell">
  {#if worktreeMenu}
    <button class="menu-backdrop" type="button" aria-label="Close worktree menu" onclick={closeMenus}></button>
    <div
      class="worktree-menu"
      role="menu"
      aria-label="Worktree Actions"
      style={`left: ${worktreeMenu.x}px; top: ${worktreeMenu.y}px`}
    >
      <button
        type="button"
        role="menuitem"
        onclick={() => {
          const worktreeId = worktreeMenu?.worktreeId;
          closeMenus();
          if (worktreeId) {
            void appState.showDiff(worktreeId);
          }
        }}
      >
        <span>Δ</span>
        <strong>Show Diff</strong>
      </button>
      <button
        type="button"
        role="menuitem"
        onclick={() => {
          const worktreeId = worktreeMenu?.worktreeId;
          closeMenus();
          if (worktreeId) {
            appState.selectWorktree(worktreeId);
            void appState.createPane();
          }
        }}
      >
        <span>+</span>
        <strong>New Tab</strong>
      </button>
    </div>
  {/if}

  <aside class="sidebar" aria-label="Worktrees and tabs">
    <div class="toolbar">
      <Button label="⌘K" title="Open Command Palette (Command K)" onclick={() => appState.perform("palette.open")} />
      <Button label="▦" title="Show Canvas" onclick={() => appState.setView("canvas")} />
      <Button label="+" title="New Tab (Command T)" onclick={() => appState.createPane()} />
      <Button label="Δ" title="Show Diff" disabled={!appState.selectedWorktreeId || appState.diffBusy} onclick={() => appState.showDiff()} />
      <div class="action-menu">
        <Button
          label="▶"
          title="Run Custom Action"
          disabled={!appState.selectedPaneId || runnableActions.length === 0}
          onclick={() => {
            actionMenuOpen = !actionMenuOpen;
          }}
        />
        {#if actionMenuOpen && runnableActions.length > 0}
          <div class="action-popover" role="menu">
            {#each runnableActions as action (action.id)}
              <button
                type="button"
                role="menuitem"
                title={`Run ${action.name}`}
                onclick={() => {
                  actionMenuOpen = false;
                  void appState.runCustomAction(action.id);
                }}
              >
                <span>{action.icon || "▶"}</span>
                <strong>{action.name}</strong>
                <small>{action.outputMode === "newPane" ? "New pane" : "Current pane"}</small>
              </button>
            {/each}
          </div>
        {/if}
      </div>
      <Button label="⚙" title="Open Settings" onclick={() => appState.setView("settings")} />
    </div>

    {#each appState.repositories as repository (repository.id)}
      <section>
        <h2>{repository.displayName}</h2>
        {#each appState.orderedWorktrees(repository.id) as worktree (worktree.id)}
          <Spine
            {worktree}
            color={repository.color}
            taskStatus={appState.worktreeTaskStatus(worktree.id)}
            unreadCount={appState.worktreeUnreadCount(worktree.id)}
            selected={worktree.id === appState.selectedWorktreeId}
            onclick={() => appState.selectWorktree(worktree.id)}
            oncontextmenu={(event) => openWorktreeMenu(event, worktree.id)}
            ondragstart={() => {
              draggedWorktree = { repoId: repository.id, worktreeId: worktree.id };
              worktreeMenu = null;
            }}
            ondragover={() => {}}
            ondrop={() => {
              if (draggedWorktree?.repoId === repository.id) {
                appState.reorderWorktree(repository.id, draggedWorktree.worktreeId, worktree.id);
              }
              draggedWorktree = null;
            }}
            ondragend={() => {
              draggedWorktree = null;
            }}
          />
          {#if worktree.id === appState.selectedWorktreeId}
            <div class="tabs">
              {#each appState.orderedPanes(worktree.id) as pane (pane.id)}
                <TabRow
                  {pane}
                  selected={pane.id === appState.selectedPaneId}
                  onclick={() => appState.selectPane(pane.id)}
                  ondragstart={() => {
                    draggedPane = { worktreeId: worktree.id, paneId: pane.id };
                  }}
                  ondragover={() => {}}
                  ondrop={() => {
                    if (draggedPane?.worktreeId === worktree.id) {
                      appState.reorderPane(worktree.id, draggedPane.paneId, pane.id);
                    }
                    draggedPane = null;
                  }}
                  ondragend={() => {
                    draggedPane = null;
                  }}
                />
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

    {#if appState.errorMessage}
      <p class="error">{appState.errorMessage}</p>
    {/if}

    {#if appState.selectedPane}
      <TerminalView
        paneId={appState.selectedPane.id}
        title={appState.selectedPane.title}
        output={appState.selectedPane.output}
        focused={true}
        buffering={appState.terminalBuffering}
        renderTerminal={appState.renderablePaneIds.has(appState.selectedPane.id)}
        onInput={(text) => {
          appState.sendInputToSelectedPane(text);
        }}
        onParsedOutput={(text) => {
          const paneId = appState.selectedPane?.id;
          if (paneId) {
            appState.detectPaneStatusFromTerminal(paneId, text);
          }
        }}
        onResize={(cols, rows) => {
          const pane = appState.selectedPane;
          if (pane) {
            appState.resizePane(pane.id, cols, rows);
          }
        }}
      />
    {:else}
      <div class="empty">No terminals open</div>
    {/if}
  </section>
</main>

<style>
  .shell {
    position: relative;
    display: grid;
    grid-template-columns: 20rem minmax(0, 1fr);
    width: 100vw;
    height: 100vh;
  }

  .menu-backdrop {
    position: fixed;
    inset: 0;
    z-index: 4;
    border: 0;
    background: transparent;
  }

  .worktree-menu {
    position: fixed;
    z-index: 6;
    display: grid;
    min-width: 10rem;
    overflow: hidden;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    box-shadow: 0 0.75rem 2rem rgb(0 0 0 / 0.2);
  }

  .worktree-menu button {
    display: grid;
    grid-template-columns: 1.25rem minmax(0, 1fr);
    gap: 0.45rem;
    align-items: center;
    min-height: 2.25rem;
    padding: 0.35rem 0.55rem;
    border: 0;
    background: transparent;
    color: CanvasText;
    font: inherit;
    text-align: left;
  }

  .worktree-menu button:hover {
    background: color-mix(in srgb, AccentColor 18%, Canvas);
  }

  .worktree-menu strong {
    font-size: 0.85rem;
    font-weight: 600;
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

  .action-menu {
    position: relative;
  }

  .action-popover {
    position: absolute;
    top: calc(100% + 0.35rem);
    left: 0;
    z-index: 5;
    display: grid;
    min-width: 13rem;
    overflow: hidden;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    box-shadow: 0 0.75rem 2rem rgb(0 0 0 / 0.2);
  }

  .action-popover button {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    gap: 0.5rem;
    align-items: center;
    min-height: 2.25rem;
    padding: 0.35rem 0.55rem;
    border: 0;
    background: transparent;
    color: CanvasText;
    font: inherit;
    text-align: left;
  }

  .action-popover button:hover {
    background: color-mix(in srgb, AccentColor 18%, Canvas);
  }

  .action-popover strong {
    overflow: hidden;
    font-size: 0.85rem;
    font-weight: 600;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .action-popover small {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
    font-size: 0.72rem;
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

  .error {
    margin: 0;
    padding: 0.5rem 0.65rem;
    border: 1px solid color-mix(in srgb, #ff3b30 45%, Canvas);
    border-radius: 6px;
    background: color-mix(in srgb, #ff3b30 12%, Canvas);
    color: CanvasText;
  }

  .empty {
    display: grid;
    place-items: center;
    border: 1px dashed color-mix(in srgb, CanvasText 22%, transparent);
    border-radius: 6px;
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }
</style>
