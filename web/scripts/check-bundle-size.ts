import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { gzipSync } from "node:zlib";

type ViteManifestEntry = {
  file: string;
  imports?: string[];
  isEntry?: boolean;
  name?: string;
};

type ViteManifest = Record<string, ViteManifestEntry>;

type BundleBudget = {
  initialJs: {
    baselineGzipBytes: number;
    maxGzipBytes: number;
    maxGrowthPercent: number;
  };
  ghosttyWasm?: {
    vendorPath: string;
    maxBytes: number;
  };
};

const outputDir = "apps/web/.svelte-kit/output/client";
const manifestPath = `${outputDir}/.vite/manifest.json`;
const budgetPath = "budgets/bundle-size.json";
const initialNodeKeys = [
  ".svelte-kit/generated/client-optimized/nodes/0.js",
  ".svelte-kit/generated/client-optimized/nodes/1.js",
  ".svelte-kit/generated/client-optimized/nodes/2.js",
];

function main(): void {
  const root = process.cwd();
  const manifest = readJson<ViteManifest>(join(root, manifestPath));
  const budget = readJson<BundleBudget>(join(root, budgetPath));
  const files = collectInitialJsFiles(manifest);
  const totalGzipBytes = files.reduce((total, file) => {
    const bytes = readFileSync(join(root, outputDir, file));
    return total + gzipSync(bytes).byteLength;
  }, 0);
  const growthLimit = Math.floor(budget.initialJs.baselineGzipBytes * (1 + budget.initialJs.maxGrowthPercent / 100));
  const allowedBytes = Math.min(budget.initialJs.maxGzipBytes, growthLimit);
  const ghosttyWasm = budget.ghosttyWasm ? measureGhosttyWasm(root, budget.ghosttyWasm) : null;

  const lines = [
    `Initial JS gzip: ${formatBytes(totalGzipBytes)}`,
    `Baseline: ${formatBytes(budget.initialJs.baselineGzipBytes)}`,
    `Allowed: ${formatBytes(allowedBytes)} (${budget.initialJs.maxGrowthPercent}% growth cap, ${formatBytes(budget.initialJs.maxGzipBytes)} absolute cap)`,
    `Files: ${files.length}`,
  ];
  if (ghosttyWasm) {
    lines.push(
      `Ghostty WASM: ${formatBytes(ghosttyWasm.bytes)}`,
      `Ghostty WASM allowed: ${formatBytes(ghosttyWasm.maxBytes)}`,
    );
  }
  process.stdout.write(lines.join("\n"));
  process.stdout.write("\n");

  if (totalGzipBytes > allowedBytes) {
    throw new Error(
      `Initial JS gzip ${formatBytes(totalGzipBytes)} exceeds budget ${formatBytes(allowedBytes)}. Update ${budgetPath} only after reviewing the bundle delta.`,
    );
  }
  if (ghosttyWasm && ghosttyWasm.bytes > ghosttyWasm.maxBytes) {
    throw new Error(
      `Ghostty WASM ${formatBytes(ghosttyWasm.bytes)} exceeds budget ${formatBytes(ghosttyWasm.maxBytes)}. Review the terminal core before updating ${budgetPath}.`,
    );
  }
}

export function collectInitialJsFiles(manifest: ViteManifest): string[] {
  const seeds = Object.entries(manifest)
    .filter(
      ([key, entry]) => entry.name === "entry/start" || entry.name === "entry/app" || initialNodeKeys.includes(key),
    )
    .map(([key]) => key);
  const visitedKeys = new Set<string>();
  const files = new Set<string>();

  function visit(key: string): void {
    if (visitedKeys.has(key)) {
      return;
    }
    const entry = manifest[key];
    if (!entry) {
      throw new Error(`Vite manifest is missing imported chunk: ${key}`);
    }
    visitedKeys.add(key);
    if (entry.file.endsWith(".js")) {
      files.add(entry.file);
    }
    for (const importedKey of entry.imports ?? []) {
      visit(importedKey);
    }
  }

  for (const seed of seeds) {
    visit(seed);
  }

  return [...files].sort();
}

function readJson<T>(path: string): T {
  if (!existsSync(path)) {
    throw new Error(`Required file not found: ${path}`);
  }
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function measureGhosttyWasm(
  root: string,
  budget: NonNullable<BundleBudget["ghosttyWasm"]>,
): { bytes: number; maxBytes: number } {
  const path = join(root, budget.vendorPath);
  if (!existsSync(path)) {
    throw new Error(`Required Ghostty WASM asset not found: ${budget.vendorPath}`);
  }
  return {
    bytes: readFileSync(path).byteLength,
    maxBytes: budget.maxBytes,
  };
}

function formatBytes(bytes: number): string {
  return `${(bytes / 1024).toFixed(1)} KiB`;
}

if (import.meta.main) {
  main();
}
