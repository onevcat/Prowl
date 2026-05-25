<script lang="ts">
  import type { Snippet } from "svelte";

  type Props = {
    text: string;
    children: Snippet;
  };

  let { text, children }: Props = $props();
</script>

<span class="tooltip-host" aria-label={text}>
  {@render children()}
  <span class="tooltip" role="tooltip">{text}</span>
</span>

<style>
  .tooltip-host {
    position: relative;
    display: inline-flex;
  }

  .tooltip {
    position: absolute;
    z-index: 20;
    bottom: calc(100% + 6px);
    left: 50%;
    max-width: 18rem;
    transform: translateX(-50%);
    padding: 0.25rem 0.45rem;
    border-radius: 5px;
    background: color-mix(in srgb, CanvasText 90%, Canvas);
    color: Canvas;
    font-size: 0.75rem;
    line-height: 1.2;
    opacity: 0;
    pointer-events: none;
    white-space: nowrap;
    transition: opacity 80ms ease;
  }

  .tooltip-host:hover .tooltip,
  .tooltip-host:focus-within .tooltip {
    opacity: 1;
  }
</style>
