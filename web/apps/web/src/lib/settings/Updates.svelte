<script lang="ts">
  import { Button } from "@prowl/ui";
</script>

<section>
  <div>
    <h2>Updates</h2>
    <p>Web builds update when the running daemon serves a new bundle.</p>
  </div>
  <Button label="↻" title="Reload Web Client" onclick={() => location.reload()} />
</section>

<style>
  section {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    padding: 1rem;
    border: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    border-radius: 8px;
    background: Canvas;
  }

  h2,
  p {
    margin: 0;
  }

  h2 {
    font-size: 1rem;
  }

  p {
    color: color-mix(in srgb, CanvasText 58%, Canvas);
  }
</style>
