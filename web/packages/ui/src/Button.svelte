<script lang="ts">
  import Tooltip from "./Tooltip.svelte";

  type Props = {
    label: string;
    title: string;
    selected?: boolean;
    disabled?: boolean;
    onclick?: () => void;
  };

  let { label, title, selected = false, disabled = false, onclick }: Props = $props();
</script>

<Tooltip text={title}>
  <button
    class:selected
    {disabled}
    aria-label={title}
    title={title}
    type="button"
    onclick={() => {
      onclick?.();
    }}
  >
    {label}
  </button>
</Tooltip>

<style>
  button {
    min-width: 2rem;
    min-height: 2rem;
    border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
    border-radius: 6px;
    background: Canvas;
    color: CanvasText;
    font: inherit;
  }

  button:hover:not(:disabled),
  button.selected {
    background: color-mix(in srgb, AccentColor 18%, Canvas);
    border-color: color-mix(in srgb, AccentColor 55%, CanvasText);
  }
</style>
