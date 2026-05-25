export type WebUpdateRegistration = {
  cleanup: () => void;
};

export type ServiceWorkerContainerLike = Pick<ServiceWorkerContainer, "register" | "controller">;

export function registerWebUpdatePrompt(
  onUpdateReady: () => void,
  container: ServiceWorkerContainerLike | undefined = globalThis.navigator?.serviceWorker,
): WebUpdateRegistration {
  let disposed = false;
  let registration: ServiceWorkerRegistration | null = null;

  if (!container) {
    return { cleanup: () => {} };
  }

  void container
    .register("/service-worker.js")
    .then((nextRegistration) => {
      if (disposed) {
        return;
      }
      registration = nextRegistration;
      registration.addEventListener("updatefound", handleUpdateFound);
    })
    .catch(() => {});

  function handleUpdateFound(): void {
    const worker = registration?.installing;
    if (!worker) {
      return;
    }
    const handleStateChange = (): void => {
      if (worker.state === "installed" && container.controller) {
        onUpdateReady();
      }
    };
    worker.addEventListener("statechange", handleStateChange, { once: true });
  }

  return {
    cleanup: () => {
      disposed = true;
      registration?.removeEventListener("updatefound", handleUpdateFound);
    },
  };
}
