import { describe, expect, test } from "bun:test";
import { renderVersion } from "./commands/version";

describe("prowl cli scaffold", () => {
  test("renders version", () => {
    expect(renderVersion()).toBe("prowl 0.0.0");
  });
});
