import { describe, expect, test } from "bun:test";
import { cliBinaryTargets, daemonBinaryTargets, releaseBinaryTargets } from "./build-binaries";

describe("release binary targets", () => {
  test("declares the WEB.md daemon release assets", () => {
    expect(daemonBinaryTargets.map((target) => target.name)).toEqual(["prowld-darwin-arm64", "prowld-linux-x64"]);
    expect(daemonBinaryTargets.map((target) => target.outfile)).toEqual([
      "dist/bin/prowld-darwin-arm64",
      "dist/bin/prowld-linux-x64",
    ]);
  });

  test("declares the WEB.md CLI release assets", () => {
    expect(cliBinaryTargets.map((target) => target.name)).toEqual(["prowl-darwin-arm64", "prowl-linux-x64"]);
    expect(cliBinaryTargets.map((target) => target.outfile)).toEqual([
      "dist/bin/prowl-darwin-arm64",
      "dist/bin/prowl-linux-x64",
    ]);
  });

  test("builds all release assets in artifact order", () => {
    expect(releaseBinaryTargets.map((target) => target.name)).toEqual([
      "prowld-darwin-arm64",
      "prowld-linux-x64",
      "prowl-darwin-arm64",
      "prowl-linux-x64",
    ]);
  });
});
