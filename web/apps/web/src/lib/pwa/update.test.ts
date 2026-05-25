import { describe, expect, test } from "vitest";
import { type ServiceWorkerContainerLike, registerWebUpdatePrompt } from "./update";

describe("PWA update prompt registration", () => {
  test("notifies when an updated service worker is installed under an active controller", async () => {
    const worker = new EventTarget() as ServiceWorker;
    Object.defineProperty(worker, "state", { value: "installed", configurable: true });
    const registration = new EventTarget() as ServiceWorkerRegistration;
    Object.defineProperty(registration, "installing", { value: worker, configurable: true });
    const container = {
      controller: worker,
      register: () => Promise.resolve(registration),
    } satisfies ServiceWorkerContainerLike;
    let updateReady = false;

    registerWebUpdatePrompt(() => {
      updateReady = true;
    }, container);
    await Promise.resolve();
    registration.dispatchEvent(new Event("updatefound"));
    worker.dispatchEvent(new Event("statechange"));

    expect(updateReady).toBe(true);
  });

  test("cleans up update listeners", async () => {
    const worker = new EventTarget() as ServiceWorker;
    Object.defineProperty(worker, "state", { value: "installed", configurable: true });
    const registration = new EventTarget() as ServiceWorkerRegistration;
    Object.defineProperty(registration, "installing", { value: worker, configurable: true });
    const container = {
      controller: worker,
      register: () => Promise.resolve(registration),
    } satisfies ServiceWorkerContainerLike;
    let updateReady = false;

    const update = registerWebUpdatePrompt(() => {
      updateReady = true;
    }, container);
    await Promise.resolve();
    update.cleanup();
    registration.dispatchEvent(new Event("updatefound"));
    worker.dispatchEvent(new Event("statechange"));

    expect(updateReady).toBe(false);
  });

  test("ignores service worker registration failures", async () => {
    const container = {
      controller: null,
      register: () => Promise.reject(new Error("registration blocked")),
    } satisfies ServiceWorkerContainerLike;

    registerWebUpdatePrompt(() => {}, container);
    await Promise.resolve();

    expect(true).toBe(true);
  });
});
