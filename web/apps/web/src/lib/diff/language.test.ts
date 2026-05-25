import { describe, expect, test } from "vitest";
import { shikiLanguageForPath } from "./language";

describe("shikiLanguageForPath", () => {
  test("maps common source paths to bundled Shiki languages", () => {
    expect(shikiLanguageForPath("src/App.svelte")).toBe("svelte");
    expect(shikiLanguageForPath("src/main.ts")).toBe("typescript");
    expect(shikiLanguageForPath("Sources/App.swift")).toBe("swift");
    expect(shikiLanguageForPath("Dockerfile")).toBe("dockerfile");
  });

  test("falls back to text for unknown files", () => {
    expect(shikiLanguageForPath("notes.unknown")).toBe("text");
    expect(shikiLanguageForPath("LICENSE")).toBe("text");
  });
});
