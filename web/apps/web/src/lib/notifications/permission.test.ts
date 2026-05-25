import { describe, expect, test } from "vitest";
import { type NotificationPermissionAPI, NotificationPermissionRequester } from "./permission";

describe("NotificationPermissionRequester", () => {
  test("requests permission on the first user gesture only", () => {
    let requests = 0;
    const notification: NotificationPermissionAPI = {
      permission: "default",
      requestPermission: () => {
        requests += 1;
        return Promise.resolve("granted");
      },
    };
    const target = new EventTarget();
    const requester = new NotificationPermissionRequester(notification);

    const cleanup = requester.registerFirstGesture(target);
    target.dispatchEvent(new Event("pointerdown"));
    target.dispatchEvent(new Event("keydown"));
    cleanup();

    expect(requests).toBe(1);
  });
});
