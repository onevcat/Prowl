import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type DaemonConfig = {
  port: number;
  bind: string;
  token: string;
  allowedOrigins: string[];
  requireTLS: boolean;
};

export function configPath(): string {
  return join(homedir(), ".prowl", "config.json");
}

export async function loadConfig(overrides: Partial<DaemonConfig> = {}): Promise<DaemonConfig> {
  const path = configPath();
  try {
    const raw = await readFile(path, "utf8");
    return { ...JSON.parse(raw), ...overrides } as DaemonConfig;
  } catch {
    const config: DaemonConfig = {
      port: 7878,
      bind: "127.0.0.1",
      token: crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", ""),
      allowedOrigins: ["http://localhost:5173", "http://127.0.0.1:5173"],
      requireTLS: false,
      ...overrides,
    };
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, `${JSON.stringify(config, null, 2)}\n`);
    return config;
  }
}

export function isAllowedOrigin(config: DaemonConfig, origin: string | null): boolean {
  if (!origin) {
    return false;
  }
  return config.allowedOrigins.includes(origin);
}
