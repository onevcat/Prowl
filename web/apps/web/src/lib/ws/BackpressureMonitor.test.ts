import { describe, expect, test } from "vitest";
import { BackpressureMonitor } from "./BackpressureMonitor";

describe("BackpressureMonitor", () => {
  test("waits before surfacing buffering state", () => {
    const monitor = new BackpressureMonitor(10, 200);

    expect(monitor.update(11, 1_000)).toBe(false);
    expect(monitor.update(11, 1_199)).toBe(false);
    expect(monitor.update(11, 1_200)).toBe(true);
  });

  test("clears buffering when the socket drains below the threshold", () => {
    const monitor = new BackpressureMonitor(10, 200);

    expect(monitor.update(11, 1_000)).toBe(false);
    expect(monitor.update(11, 1_250)).toBe(true);
    expect(monitor.buffering).toBe(true);
    expect(monitor.update(10, 1_300)).toBe(false);
    expect(monitor.buffering).toBe(false);
  });
});
