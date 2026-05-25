export type NotificationPermissionAPI = {
  permission: NotificationPermission;
  requestPermission: () => Promise<NotificationPermission>;
};

export type GestureTarget = Pick<EventTarget, "addEventListener" | "removeEventListener">;

export class NotificationPermissionRequester {
  #requested = false;

  constructor(private readonly notification: NotificationPermissionAPI | undefined = globalThis.Notification) {}

  request(): void {
    if (this.#requested || !this.notification) {
      return;
    }
    if (this.notification.permission !== "default") {
      this.#requested = true;
      return;
    }
    this.#requested = true;
    void this.notification.requestPermission();
  }

  registerFirstGesture(target: GestureTarget): () => void {
    const request = (): void => {
      this.request();
      cleanup();
    };
    const cleanup = (): void => {
      target.removeEventListener("pointerdown", request);
      target.removeEventListener("keydown", request);
    };
    target.addEventListener("pointerdown", request, { passive: true });
    target.addEventListener("keydown", request);
    return cleanup;
  }
}
