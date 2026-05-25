import { describe, expect, test } from "bun:test";
import { GitOperationQueue } from "./OperationQueue";

test("serializes operations for the same repository", async () => {
  const queue = new GitOperationQueue();
  const events: string[] = [];
  let releaseFirst = () => {};

  const first = queue.run("repo-1", async () => {
    events.push("first:start");
    await new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    events.push("first:end");
  });
  const second = queue.run("repo-1", () => {
    events.push("second:start");
  });

  await Promise.resolve();
  expect(events).toEqual(["first:start"]);
  releaseFirst();
  await Promise.all([first, second]);

  expect(events).toEqual(["first:start", "first:end", "second:start"]);
  expect(queue.size).toBe(0);
});

describe("GitOperationQueue", () => {
  test("allows independent repositories to enter without waiting on each other", async () => {
    const queue = new GitOperationQueue();
    const events: string[] = [];
    let releaseFirst = () => {};

    const first = queue.run("repo-1", async () => {
      events.push("repo-1:start");
      await new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
      events.push("repo-1:end");
    });
    const second = queue.run("repo-2", () => {
      events.push("repo-2:start");
    });

    await second;
    expect(events).toEqual(["repo-1:start", "repo-2:start"]);
    releaseFirst();
    await first;

    expect(events).toEqual(["repo-1:start", "repo-2:start", "repo-1:end"]);
    expect(queue.size).toBe(0);
  });
});
