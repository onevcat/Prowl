import { describe, expect, test } from "bun:test";
import { daemonBinaryTargets } from "./build-binaries";

describe("release binary targets", () => {
  test("declares the WEB.md daemon release assets", () => {
    expect(daemonBinaryTargets.map((target) => target.name)).toEqual(["prowld-darwin-arm64", "prowld-linux-x64"]);
    expect(daemonBinaryTargets.map((target) => target.outfile)).toEqual([
      "dist/bin/prowld-darwin-arm64",
      "dist/bin/prowld-linux-x64",
    ]);
  });
});
