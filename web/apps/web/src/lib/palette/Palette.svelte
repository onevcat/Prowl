<script lang="ts">
  import { getContext, tick } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import { clampPaletteIndex, nextPaletteIndex } from "./navigation";
  import { filterPaletteItems, filterPaletteItemsAsync, fuzzyWorkerThreshold } from "./results";

  const appState = getContext<AppState>(appStateKey);
  let selectedIndex = $state(0);
  let input = $state<HTMLInputElement>();
  let results = $state(filterPaletteItems(appState.paletteItems, appState.paletteQuery));
  let searching = $state(false);
  let searchRequestId = 0;

  $effect(() => {
    const items = appState.paletteItems;
    const query = appState.paletteQuery;
    const requestId = ++searchRequestId;
    searching = items.length > fuzzyWorkerThreshold && query.trim().length > 0;
    void filterPaletteItemsAsync(items, query)
      .then((nextResults) => {
        if (requestId === searchRequestId) {
          results = nextResults;
        }
      })
      .catch(() => {
        if (requestId === searchRequestId) {
          results = filterPaletteItems(items, query);
        }
      })
      .finally(() => {
        if (requestId === searchRequestId) {
          searching = false;
        }
      });
  });

  $effect(() => {
    if (appState.paletteOpen) {
      selectedIndex = 0;
      void tick().then(() => input?.focus());
    }
  });

  $effect(() => {
    selectedIndex = clampPaletteIndex(selectedIndex, results.length);
  });

  function invokeSelected(): void {
    const item = results[selectedIndex];
    if (item) {
      appState.invokePaletteItem(item);
    }
  }
</script>

{#if appState.paletteOpen}
  <div
    class="backdrop"
    role="presentation"
    onclick={() => appState.perform("palette.close")}
    onkeydown={(event) => {
      if (event.key === "Escape") {
        appState.perform("palette.close");
      }
    }}
  >
    <section
      class="palette"
      role="dialog"
      aria-modal="true"
      tabindex="-1"
      onclick={(event) => event.stopPropagation()}
      onkeydown={(event) => {
        if (event.key === "Escape") {
          appState.perform("palette.close");
        }
        event.stopPropagation();
      }}
    >
      <input
        bind:this={input}
        aria-label="Command Palette"
        placeholder="Search tabs, worktrees, repos, settings, actions"
        value={appState.paletteQuery}
        oninput={(event) => appState.setPaletteQuery(event.currentTarget.value)}
        onkeydown={(event) => {
          if (event.key === "ArrowDown") {
            event.preventDefault();
            selectedIndex = nextPaletteIndex(selectedIndex, results.length, 1);
          } else if (event.key === "ArrowUp") {
            event.preventDefault();
            selectedIndex = nextPaletteIndex(selectedIndex, results.length, -1);
          } else if (event.key === "Enter") {
            event.preventDefault();
            invokeSelected();
          } else if (event.key === "Escape") {
            appState.perform("palette.close");
          }
        }}
      />

      <div class="results">
        {#if searching}
          <p class="searching">Searching...</p>
        {/if}
        {#each results as item, index (item.id)}
          <button class:selected={index === selectedIndex} type="button" onclick={() => appState.invokePaletteItem(item)}>
            <span>{item.title}</span>
            <small>{item.section} · {item.subtitle}</small>
          </button>
        {/each}
      </div>
    </section>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 50;
    display: grid;
    align-items: start;
    justify-items: center;
    padding-top: 12vh;
    background: rgb(0 0 0 / 0.25);
  }

  .palette {
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    width: min(44rem, calc(100vw - 2rem));
    max-height: 70vh;
    overflow: hidden;
    border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
    border-radius: 8px;
    background: Canvas;
    box-shadow: 0 1.5rem 5rem rgb(0 0 0 / 0.28);
  }

  input {
    width: 100%;
    min-height: 3rem;
    padding: 0 1rem;
    border: 0;
    border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
    background: Canvas;
    color: CanvasText;
    outline: none;
  }

  .results {
    overflow: auto;
    padding: 0.4rem;
  }

  button {
    display: grid;
    width: 100%;
    min-height: 3rem;
    padding: 0.35rem 0.65rem;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: CanvasText;
    text-align: left;
  }

  button.selected,
  button:hover {
    background: color-mix(in srgb, AccentColor 18%, Canvas);
  }

  .searching {
    margin: 0;
    padding: 0.5rem 0.65rem;
    color: color-mix(in srgb, CanvasText 58%, Canvas);
    font-size: 0.82rem;
  }

  small {
    overflow: hidden;
    color: color-mix(in srgb, CanvasText 58%, Canvas);
    text-overflow: ellipsis;
    white-space: nowrap;
  }
</style>
