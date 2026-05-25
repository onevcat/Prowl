import type { BundledLanguage } from "shiki";

const languageByExtension: Record<string, BundledLanguage> = {
  c: "c",
  cc: "cpp",
  cpp: "cpp",
  css: "css",
  go: "go",
  h: "c",
  hpp: "cpp",
  html: "html",
  java: "java",
  js: "javascript",
  json: "json",
  jsx: "jsx",
  kt: "kotlin",
  kts: "kotlin",
  md: "markdown",
  mjs: "javascript",
  py: "python",
  rb: "ruby",
  rs: "rust",
  scss: "scss",
  sh: "shellscript",
  svelte: "svelte",
  swift: "swift",
  ts: "typescript",
  tsx: "tsx",
  vue: "vue",
  yaml: "yaml",
  yml: "yaml",
  zig: "zig",
};

const languageByFilename: Record<string, BundledLanguage> = {
  Dockerfile: "dockerfile",
  Makefile: "makefile",
};

export function shikiLanguageForPath(path: string): BundledLanguage | "text" {
  const filename = path.split("/").at(-1) ?? path;
  const byFilename = languageByFilename[filename];
  if (byFilename) {
    return byFilename;
  }
  const extension = filename.split(".").at(-1)?.toLowerCase();
  return extension ? (languageByExtension[extension] ?? "text") : "text";
}
