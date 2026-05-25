<script lang="ts" module>
  function percentile(samples: number[], percentileValue: number): number | null {
    if (samples.length === 0) {
      return null;
    }
    const sorted = [...samples].sort((a, b) => a - b);
    const index = Math.min(sorted.length - 1, Math.ceil((percentileValue / 100) * sorted.length) - 1);
    return sorted[index] ?? null;
  }

  function formatMs(value: number | null): string {
    return value === null ? "..." : `${Math.round(value)} ms`;
  }

  function readHeapSize(): number | null {
    const memory = (performance as Performance & { memory?: { usedJSHeapSize?: number } }).memory;
    return memory?.usedJSHeapSize ? Math.round(memory.usedJSHeapSize / 1024 / 1024) : null;
  }
</script>

<script lang="ts">
  import { getContext } from "svelte";
  import { appStateKey, type AppState } from "$lib/state/AppState.svelte";

  const appState = getContext<AppState>(appStateKey);
  let fps = $state(0);
  let heap = $state<number | null>(null);

  $effect(() => {
    let frames = 0;
    let last = performance.now();
    let frame = 0;

    function tick(now: number): void {
      frames += 1;
      if (now - last >= 1_000) {
        fps = Math.round((frames * 1_000) / (now - last));
        frames = 0;
        last = now;
        heap = readHeapSize();
      }
      frame = requestAnimationFrame(tick);
    }

    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  });

  const inputP50 = $derived(percentile(appState.metrics.inputLatencySamples, 50));
  const inputP99 = $derived(percentile(appState.metrics.inputLatencySamples, 99));
  const wsP50 = $derived(percentile(appState.metrics.wsRttSamples, 50));
  const wsP99 = $derived(percentile(appState.metrics.wsRttSamples, 99));
  const reconnectP50 = $derived(percentile(appState.metrics.wsReconnectSamples, 50));
  const reconnectP99 = $derived(percentile(appState.metrics.wsReconnectSamples, 99));
  const switchP50 = $derived(percentile(appState.metrics.worktreeSwitchSamples, 50));
  const switchP99 = $derived(percentile(appState.metrics.worktreeSwitchSamples, 99));
  const paletteP50 = $derived(percentile(appState.metrics.paletteOpenSamples, 50));
  const paletteP99 = $derived(percentile(appState.metrics.paletteOpenSamples, 99));
  const rendererCount = $derived(appState.activeRendererCount);
</script>

{#if import.meta.env.DEV && appState.settings.advanced.performanceHUD}
  <aside aria-label="Performance HUD">
    <div>
      <span>Input</span>
      <strong>{formatMs(inputP50)} / {formatMs(inputP99)}</strong>
    </div>
    <div>
      <span>WS RTT</span>
      <strong>{formatMs(wsP50)} / {formatMs(wsP99)}</strong>
    </div>
    <div>
      <span>Reconnect</span>
      <strong>{formatMs(reconnectP50)} / {formatMs(reconnectP99)}</strong>
    </div>
    <div>
      <span>Switch</span>
      <strong>{formatMs(switchP50)} / {formatMs(switchP99)}</strong>
    </div>
    <div>
      <span>Palette</span>
      <strong>{formatMs(paletteP50)} / {formatMs(paletteP99)}</strong>
    </div>
    <div>
      <span>Renderers</span>
      <strong>{rendererCount} / 8</strong>
    </div>
    <div>
      <span>FPS</span>
      <strong>{fps || "..."}</strong>
    </div>
    <div>
      <span>Heap</span>
      <strong>{heap === null ? "n/a" : `${heap} MB`}</strong>
    </div>
  </aside>
{/if}

<style>
  aside {
    position: fixed;
    right: 0.75rem;
    bottom: 0.75rem;
    z-index: 20;
    display: grid;
    grid-template-columns: repeat(8, auto);
    gap: 0.6rem;
    align-items: center;
    padding: 0.55rem 0.65rem;
    border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
    border-radius: 8px;
    background: color-mix(in srgb, Canvas 88%, transparent);
    box-shadow: 0 0.35rem 1.5rem color-mix(in srgb, CanvasText 18%, transparent);
    backdrop-filter: blur(14px);
  }

  div {
    display: grid;
    gap: 0.1rem;
    min-width: 4.5rem;
  }

  span {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
    font-size: 0.72rem;
  }

  strong {
    font-size: 0.78rem;
    font-weight: 650;
  }
</style>
