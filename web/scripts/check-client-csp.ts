import { existsSync, readFileSync } from "node:fs";

const requiredDirectives: Record<string, string[]> = {
  "default-src": ["'self'"],
  "script-src": ["'self'", "'wasm-unsafe-eval'"],
  "style-src": ["'self'", "'unsafe-inline'"],
  "connect-src": ["'self'", "ws://127.0.0.1:*", "wss:"],
  "img-src": ["'self'", "data:", "blob:"],
  "worker-src": ["'self'", "blob:"],
  "font-src": ["'self'"],
  "object-src": ["'none'"],
  "base-uri": ["'self'"],
  "frame-ancestors": ["'none'"],
};

function main(): void {
  const violations = findClientCspViolations("apps/web/svelte.config.js");
  if (violations.length === 0) {
    process.stdout.write("Client CSP directives: ok\n");
    return;
  }
  throw new Error(["Prowl Web client CSP is missing required WEB.md directives.", ...violations].join("\n"));
}

export function findClientCspViolations(configPath: string): string[] {
  if (!existsSync(configPath)) {
    throw new Error(`File not found: ${configPath}`);
  }
  const source = readFileSync(configPath, "utf8");
  const violations: string[] = [];
  for (const [directive, requiredValues] of Object.entries(requiredDirectives)) {
    const values = directiveValues(source, directive);
    if (!values) {
      violations.push(`- missing ${directive}`);
      continue;
    }
    for (const requiredValue of requiredValues) {
      if (!values.includes(requiredValue)) {
        violations.push(`- ${directive} missing ${requiredValue}`);
      }
    }
  }
  return violations;
}

function directiveValues(source: string, directive: string): string[] | null {
  const match = new RegExp(`["']${escapeRegExp(directive)}["']\\s*:\\s*\\[([^\\]]*)\\]`, "m").exec(source);
  if (!match?.[1]) {
    return null;
  }
  return [...match[1].matchAll(/"([^"]*)"|'([^']*)'/g)]
    .map((valueMatch) => valueMatch[1] ?? valueMatch[2])
    .filter((value): value is string => typeof value === "string");
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

if (import.meta.main) {
  main();
}
