<script lang="ts">
  import type { AppState } from "$lib/state/AppState.svelte";

  type Props = {
    appState: AppState;
  };

  let { appState }: Props = $props();
</script>

<main class="auth-shell">
  <form
    class="auth-panel"
    onsubmit={(event) => {
      event.preventDefault();
      void appState.login();
    }}
  >
    <div class="heading">
      <p class="eyebrow">Prowl Web</p>
      <h1>Connect to prowld</h1>
    </div>

    <label>
      <span>Daemon URL</span>
      <input
        autocomplete="off"
        spellcheck="false"
        value={appState.daemonURL}
        oninput={(event) => appState.setDaemonURL(event.currentTarget.value)}
      />
    </label>

    <label>
      <span>Token</span>
      <input
        autocomplete="current-password"
        type="password"
        value={appState.loginToken}
        oninput={(event) => appState.setLoginToken(event.currentTarget.value)}
      />
    </label>

    {#if appState.loginError || appState.errorMessage}
      <p class="error">{appState.loginError ?? appState.errorMessage}</p>
    {/if}

    <button disabled={appState.loginBusy} title="Connect to daemon" type="submit">
      {appState.loginBusy ? "Connecting" : "Connect"}
    </button>
  </form>
</main>

<style>
  .auth-shell {
    display: grid;
    min-height: 100vh;
    place-items: center;
    padding: 2rem;
    background: Canvas;
  }

  .auth-panel {
    display: grid;
    width: min(28rem, 100%);
    gap: 1rem;
    padding: 1.25rem;
    border: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
    border-radius: 8px;
    background: Canvas;
  }

  .heading {
    display: grid;
    gap: 0.25rem;
  }

  .eyebrow,
  h1,
  .error {
    margin: 0;
  }

  .eyebrow {
    color: color-mix(in srgb, CanvasText 62%, transparent);
    font-size: 0.85rem;
  }

  h1 {
    font-size: 1.4rem;
    font-weight: 650;
  }

  label {
    display: grid;
    gap: 0.4rem;
  }

  label span {
    color: color-mix(in srgb, CanvasText 68%, transparent);
    font-size: 0.9rem;
  }

  input {
    width: 100%;
    min-height: 2.5rem;
    padding: 0 0.7rem;
    border: 1px solid color-mix(in srgb, CanvasText 18%, transparent);
    border-radius: 6px;
    background: Canvas;
    color: CanvasText;
  }

  input:focus {
    border-color: AccentColor;
    outline: 2px solid color-mix(in srgb, AccentColor 25%, transparent);
  }

  button {
    min-height: 2.5rem;
    border: 0;
    border-radius: 6px;
    background: AccentColor;
    color: AccentColorText;
    cursor: pointer;
    font-weight: 650;
  }

  button:disabled {
    cursor: default;
    opacity: 0.65;
  }

  .error {
    color: Mark;
    font-size: 0.9rem;
  }
</style>
