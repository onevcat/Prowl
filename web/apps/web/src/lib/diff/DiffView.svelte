<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";

  type DiffFile = {
    path: string;
    lines: string[];
  };

  const appState = getContext<AppState>(appStateKey);
  let mode = $state<"unified" | "split">("unified");
  let selectedPath = $state<string | null>(null);
  let files = $derived(parseDiff(appState.diff?.text ?? ""));
  let selectedFile = $derived(files.find((file) => file.path === selectedPath) ?? files[0] ?? null);

  $effect(() => {
    if (!selectedPath || !files.some((file) => file.path === selectedPath)) {
      selectedPath = files[0]?.path ?? null;
    }
  });

  function parseDiff(diff: string): DiffFile[] {
    const parsed: DiffFile[] = [];
    let current: DiffFile | null = null;
    for (const line of diff.split("\n")) {
      if (line.startsWith("diff --git ")) {
        current = { path: line.split(" b/")[1] ?? line, lines: [line] };
        parsed.push(current);
        continue;
      }
      current?.lines.push(line);
    }
    return parsed;
  }

  function lineClass(line: string): string {
    if (line.startsWith("+") && !line.startsWith("+++")) {
      return "added";
    }
    if (line.startsWith("-") && !line.startsWith("---")) {
      return "removed";
    }
    if (line.startsWith("@@") || line.startsWith("diff --git") || line.startsWith("index ")) {
      return "meta";
    }
    return "";
  }
</script>

<main class="diff">
  <header>
    <div>
      <h1>{appState.selectedWorktree?.name ?? "Diff"}</h1>
      <p>{appState.diff ? `${files.length} files · ${new Date(appState.diff.generatedAt).toLocaleTimeString()}` : "No diff loaded"}</p>
    </div>
    <div class="actions">
      <Button label="↻" title="Refresh Diff" disabled={appState.diffBusy} onclick={() => appState.showDiff()} />
      <Button label="⇄" title="Toggle Unified or Side-by-side Diff" onclick={() => (mode = mode === "unified" ? "split" : "unified")} />
      <Button label="←" title="Back to Shelf" onclick={() => appState.setView("shelf")} />
    </div>
  </header>

  <section class="body">
    <aside aria-label="Changed files">
      {#if files.length === 0}
        <p class="empty">No changes</p>
      {:else}
        {#each files as file (file.path)}
          <button class:selected={file.path === selectedFile?.path} type="button" onclick={() => (selectedPath = file.path)}>
            {file.path}
          </button>
        {/each}
      {/if}
    </aside>

    <article class:split={mode === "split"}>
      {#if selectedFile}
        {#each selectedFile.lines as line, index (`${selectedFile.path}-${index}`)}
          <pre class={lineClass(line)}>{line}</pre>
        {/each}
      {:else}
        <div class="empty">No diff content</div>
      {/if}
    </article>
  </section>
</main>

<style>
  .diff {
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    width: 100vw;
    height: 100vh;
    background: color-mix(in srgb, CanvasText 4%, Canvas);
  }

  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.75rem;
    border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    background: Canvas;
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

  .actions {
    display: flex;
    gap: 0.4rem;
  }

  .body {
    display: grid;
    grid-template-columns: 18rem minmax(0, 1fr);
    min-height: 0;
  }

  aside {
    overflow: auto;
    border-right: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
    background: color-mix(in srgb, CanvasText 3%, Canvas);
  }

  aside button {
    display: block;
    width: 100%;
    min-height: 2.25rem;
    padding: 0.35rem 0.65rem;
    border: 0;
    background: transparent;
    color: CanvasText;
    overflow: hidden;
    text-align: left;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  aside button:hover,
  aside button.selected {
    background: color-mix(in srgb, AccentColor 18%, Canvas);
  }

  article {
    overflow: auto;
    padding: 0.75rem;
    background: Canvas;
  }

  article.split {
    columns: 2 32rem;
    column-gap: 1rem;
  }

  pre {
    min-height: 1.35rem;
    margin: 0;
    padding: 0.08rem 0.5rem;
    overflow: visible;
    border-left: 3px solid transparent;
    font: 0.82rem ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
    white-space: pre-wrap;
  }

  pre.added {
    border-color: color-mix(in srgb, #34c759 70%, CanvasText);
    background: color-mix(in srgb, #34c759 14%, Canvas);
  }

  pre.removed {
    border-color: color-mix(in srgb, #ff3b30 70%, CanvasText);
    background: color-mix(in srgb, #ff3b30 13%, Canvas);
  }

  pre.meta {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  .empty {
    padding: 0.75rem;
  }
</style>
