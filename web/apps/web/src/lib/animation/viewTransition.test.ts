import { describe, expect, test } from "vitest";
import { runViewTransition } from "./viewTransition";

describe("runViewTransition", () => {
  test("runs the update directly when the API is unavailable", () => {
    let updated = false;

    runViewTransition(() => {
      updated = true;
    }, {} as Document);

    expect(updated).toBe(true);
  });

  test("uses startViewTransition when available", () => {
    let transitioned = false;
    let updated = false;
    const documentRef = {
      startViewTransition(update: () => void) {
        transitioned = true;
        update();
      },
    } as Document & { startViewTransition: (update: () => void) => void };

    runViewTransition(() => {
      updated = true;
    }, documentRef);

    expect(transitioned).toBe(true);
    expect(updated).toBe(true);
  });
});
