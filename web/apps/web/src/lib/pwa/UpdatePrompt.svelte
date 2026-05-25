<script lang="ts">
  import { Button } from "@prowl/ui";
  import { onMount } from "svelte";
  import { registerWebUpdatePrompt } from "./update";

  let updateReady = $state(false);

  onMount(() => {
    const update = registerWebUpdatePrompt(() => {
      updateReady = true;
    });
    return update.cleanup;
  });
</script>

{#if updateReady}
  <aside aria-live="polite" class="update-prompt" role="status">
    <span>A new web bundle is ready.</span>
    <Button label="↻" title="Reload to Apply Update" onclick={() => location.reload()} />
  </aside>
{/if}

<style>
  .update-prompt {
    position: fixed;
    right: 1rem;
    bottom: 1rem;
    z-index: 30;
    display: flex;
    align-items: center;
    gap: 0.75rem;
    max-width: min(24rem, calc(100vw - 2rem));
    padding: 0.65rem 0.75rem;
    border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
    border-radius: 8px;
    background: Canvas;
    box-shadow: 0 0.5rem 1.5rem color-mix(in srgb, CanvasText 16%, transparent);
    color: CanvasText;
  }

  span {
    min-width: 0;
  }
</style>
