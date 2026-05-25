<script lang="ts">
  import { Button } from "@prowl/ui";
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";
  import { highlightDiffFilesInWorker } from "./highlight";
  import { splitDiffRows, type DiffFile, type DiffLine } from "./model";
  import { visibleRange } from "./virtual";
  import { parseGitDiffInWorker } from "./worker";

  const diffRowHeight = 22;
  const diffOverscan = 16;
  const fileRowHeight = 36;
  const fileOverscan = 8;
  const appState = getContext<AppState>(appStateKey);
  let mode = $state<"unified" | "split">("unified");
  let selectedPath = $state<string | null>(null);
  let files = $state<DiffFile[]>([]);
  let highlightedLinesByPath = $state<Map<string, string[]>>(new Map());
  let parsing = $state(false);
  let highlighting = $state(false);
  let parseError = $state<string | null>(null);
  let scrollTop = $state(0);
  let viewportHeight = $state(0);
  let fileListScrollTop = $state(0);
  let fileListViewportHeight = $state(0);
  let scrollViewport = $state<HTMLElement | null>(null);
  let fileListViewport = $state<HTMLElement | null>(null);
  let parseRequestId = 0;
  let highlightRequestId = 0;
  let selectedFile = $derived(files.find((file) => file.path === selectedPath) ?? files[0] ?? null);
  let splitRows = $derived(selectedFile ? splitDiffRows(selectedFile.lines) : []);
  let fileRange = $derived(
    visibleRange(files.length, fileListScrollTop, fileListViewportHeight, fileRowHeight, fileOverscan),
  );
  let visibleFiles = $derived(files.slice(fileRange.start, fileRange.end));
  let unifiedRange = $derived(
    visibleRange(selectedFile?.lines.length ?? 0, scrollTop, viewportHeight, diffRowHeight, diffOverscan),
  );
  let splitRange = $derived(visibleRange(splitRows.length, scrollTop, viewportHeight, diffRowHeight, diffOverscan));
  let visibleUnifiedLines = $derived(
    selectedFile ? selectedFile.lines.slice(unifiedRange.start, unifiedRange.end) : [],
  );
  let visibleSplitRows = $derived(splitRows.slice(splitRange.start, splitRange.end));

  $effect(() => {
    const diffText = appState.diff?.text ?? "";
    const requestId = ++parseRequestId;
    if (!diffText) {
      files = [];
      highlightedLinesByPath = new Map();
      parsing = false;
      highlighting = false;
      parseError = null;
      return;
    }
    parsing = true;
    parseError = null;
    void parseGitDiffInWorker(diffText)
      .then((parsedFiles) => {
        if (requestId === parseRequestId) {
          files = parsedFiles;
          void highlightParsedFiles(parsedFiles);
        }
      })
      .catch((error) => {
        if (requestId === parseRequestId) {
          parseError = error instanceof Error ? error.message : String(error);
          files = [];
          highlightedLinesByPath = new Map();
        }
      })
      .finally(() => {
        if (requestId === parseRequestId) {
          parsing = false;
        }
      });
  });

  $effect(() => {
    if (!selectedPath || !files.some((file) => file.path === selectedPath)) {
      selectedPath = files[0]?.path ?? null;
    }
  });

  $effect(() => {
    selectedFile?.path;
    mode;
    scrollTop = 0;
    if (scrollViewport) {
      scrollViewport.scrollTop = 0;
      viewportHeight = scrollViewport.clientHeight;
    }
  });

  $effect(() => {
    files.length;
    if (fileListViewport) {
      fileListViewportHeight = fileListViewport.clientHeight;
    }
  });

  function lineNumber(line: DiffLine | null, side: "old" | "new"): string {
    const value = side === "old" ? line?.oldLine : line?.newLine;
    return value === null || value === undefined ? "" : String(value);
  }

  function highlightedLine(file: DiffFile, line: DiffLine, index: number): string {
    if (line.inlineSegments) {
      return renderInlineSegments(line);
    }
    return highlightedLinesByPath.get(file.path)?.[index] ?? escapeHtml(line.text);
  }

  function highlightedSplitLine(file: DiffFile, line: DiffLine | null): string {
    if (!line) {
      return "";
    }
    if (line.inlineSegments) {
      return renderInlineSegments(line);
    }
    const index = file.lines.indexOf(line);
    return index === -1 ? escapeHtml(line.text) : highlightedLine(file, line, index);
  }

  function renderInlineSegments(line: DiffLine): string {
    return (
      line.inlineSegments
        ?.map((segment) => {
          const text = escapeHtml(segment.text);
          return segment.changed ? `<span class="changed">${text}</span>` : text;
        })
        .join("") ?? escapeHtml(line.text)
    );
  }

  function syncScrollMetrics(): void {
    if (!scrollViewport) {
      return;
    }
    scrollTop = scrollViewport.scrollTop;
    viewportHeight = scrollViewport.clientHeight;
  }

  function syncFileListMetrics(): void {
    if (!fileListViewport) {
      return;
    }
    fileListScrollTop = fileListViewport.scrollTop;
    fileListViewportHeight = fileListViewport.clientHeight;
  }

  async function highlightParsedFiles(parsedFiles: DiffFile[]): Promise<void> {
    const requestId = ++highlightRequestId;
    highlighting = parsedFiles.length > 0;
    try {
      const highlighted = await highlightDiffFilesInWorker(parsedFiles);
      if (requestId === highlightRequestId) {
        highlightedLinesByPath = highlighted;
      }
    } catch {
      if (requestId === highlightRequestId) {
        highlightedLinesByPath = new Map();
      }
    } finally {
      if (requestId === highlightRequestId) {
        highlighting = false;
      }
    }
  }

  function escapeHtml(value: string): string {
    return value
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;");
  }
</script>

<main class="diff">
  <header>
    <div>
      <h1>{appState.selectedWorktree?.name ?? "Diff"}</h1>
      <p>
        {#if parsing}
          Parsing diff...
        {:else if highlighting}
          Highlighting diff...
        {:else}
          {appState.diff ? `${files.length} files · ${new Date(appState.diff.generatedAt).toLocaleTimeString()}` : "No diff loaded"}
        {/if}
      </p>
    </div>
    <div class="actions">
      <Button label="↻" title="Refresh Diff" disabled={appState.diffBusy} onclick={() => appState.showDiff()} />
      <Button label="⇄" title="Toggle Unified or Side-by-side Diff" onclick={() => (mode = mode === "unified" ? "split" : "unified")} />
      <Button label="←" title="Back to Shelf" onclick={() => appState.setView("shelf")} />
    </div>
  </header>

  <section class="body">
    <aside bind:this={fileListViewport} aria-label="Changed files" onscroll={syncFileListMetrics}>
      {#if parseError}
        <p class="empty">{parseError}</p>
      {:else if files.length === 0}
        <p class="empty">No changes</p>
      {:else}
        <div
          class="file-window"
          style={`padding-top: ${fileRange.offsetTop}px; padding-bottom: ${fileRange.offsetBottom}px;`}
        >
          {#each visibleFiles as file (file.path)}
            <button
              class:selected={file.path === selectedFile?.path}
              type="button"
              onclick={() => (selectedPath = file.path)}
            >
              <span>{file.path}</span>
              <small>+{file.added} -{file.removed}</small>
            </button>
          {/each}
        </div>
      {/if}
    </aside>

    <article bind:this={scrollViewport} onscroll={syncScrollMetrics}>
      {#if selectedFile}
        {#if mode === "split"}
          <div class="virtual-space" aria-label="Side-by-side diff">
            <div
              class="split-view virtual-window"
              style={`padding-top: ${splitRange.offsetTop}px; padding-bottom: ${splitRange.offsetBottom}px;`}
            >
            {#each visibleSplitRows as row, index (`${selectedFile.path}-split-${splitRange.start + index}`)}
              <div class={`cell gutter ${row.oldLine?.kind ?? ""}`}>{lineNumber(row.oldLine, "old")}</div>
              <pre class={`cell ${row.oldLine?.kind ?? ""}`}>{@html highlightedSplitLine(selectedFile, row.oldLine)}</pre>
              <div class={`cell gutter ${row.newLine?.kind ?? ""}`}>{lineNumber(row.newLine, "new")}</div>
              <pre class={`cell ${row.newLine?.kind ?? ""}`}>{@html highlightedSplitLine(selectedFile, row.newLine)}</pre>
            {/each}
            </div>
          </div>
        {:else}
          <div class="virtual-space" aria-label="Unified diff">
            <div
              class="unified-view virtual-window"
              style={`padding-top: ${unifiedRange.offsetTop}px; padding-bottom: ${unifiedRange.offsetBottom}px;`}
            >
            {#each visibleUnifiedLines as line, index (`${selectedFile.path}-${unifiedRange.start + index}`)}
              <div class={`gutter ${line.kind}`}>{lineNumber(line, "old")}</div>
              <div class={`gutter ${line.kind}`}>{lineNumber(line, "new")}</div>
              <pre class={line.kind}>{@html highlightedLine(selectedFile, line, unifiedRange.start + index)}</pre>
            {/each}
            </div>
          </div>
        {/if}
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

  .file-window {
    min-height: 100%;
  }

  aside button {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 0.5rem;
    width: 100%;
    height: 36px;
    padding: 0.35rem 0.65rem;
    border: 0;
    background: transparent;
    color: CanvasText;
    overflow: hidden;
    text-align: left;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  aside button span {
    overflow: hidden;
    text-overflow: ellipsis;
  }

  aside button small {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
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

  .virtual-space {
    min-width: max-content;
  }

  .unified-view {
    display: grid;
    grid-template-columns: 3rem 3rem minmax(0, 1fr);
  }

  .split-view {
    display: grid;
    grid-template-columns: 3rem minmax(0, 1fr) 3rem minmax(0, 1fr);
  }

  pre {
    height: 22px;
    margin: 0;
    padding: 0.08rem 0.5rem;
    overflow: hidden;
    border-left: 3px solid transparent;
    font: 0.82rem ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
    line-height: 1.15rem;
    white-space: pre;
  }

  .cell {
    height: 22px;
  }

  .gutter {
    height: 22px;
    padding: 0.08rem 0.4rem;
    color: color-mix(in srgb, CanvasText 45%, Canvas);
    font: 0.82rem ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
    line-height: 1.15rem;
    text-align: right;
    user-select: none;
  }

  pre.added {
    border-color: color-mix(in srgb, #34c759 70%, CanvasText);
    background: color-mix(in srgb, #34c759 14%, Canvas);
  }

  .gutter.added {
    background: color-mix(in srgb, #34c759 10%, Canvas);
  }

  pre.removed {
    border-color: color-mix(in srgb, #ff3b30 70%, CanvasText);
    background: color-mix(in srgb, #ff3b30 13%, Canvas);
  }

  .gutter.removed {
    background: color-mix(in srgb, #ff3b30 10%, Canvas);
  }

  pre.meta {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }

  pre :global(span.changed) {
    border-radius: 3px;
    background: color-mix(in srgb, AccentColor 24%, transparent);
  }

  .empty {
    padding: 0.75rem;
  }
</style>
