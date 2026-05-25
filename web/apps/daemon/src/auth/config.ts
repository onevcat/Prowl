import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type DaemonConfig = {
  port: number;
  bind: string;
  token: string;
  allowedOrigins: string[];
  requireTLS: boolean;
  tlsCertPath?: string;
  tlsKeyPath?: string;
};

const defaultBind = "127.0.0.1";
const defaultAllowedOrigins = ["http://localhost:5173", "http://127.0.0.1:5173"];

export function configPath(): string {
  return join(homedir(), ".prowl", "config.json");
}

export async function loadConfig(overrides: Partial<DaemonConfig> = {}): Promise<DaemonConfig> {
  const path = configPath();
  try {
    const raw = await readFile(path, "utf8");
    return normalizeConfig(JSON.parse(raw) as Partial<DaemonConfig>, overrides);
  } catch {
    const config = normalizeConfig(
      {
        port: 7878,
        bind: defaultBind,
        token: generateToken(),
        allowedOrigins: defaultAllowedOrigins,
      },
      overrides,
    );
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

export function normalizeConfig(raw: Partial<DaemonConfig>, overrides: Partial<DaemonConfig> = {}): DaemonConfig {
  const bind = overrides.bind ?? raw.bind ?? defaultBind;
  const bindChangedByOverride = overrides.bind !== undefined && overrides.bind !== raw.bind;
  const requireTLS =
    overrides.requireTLS ??
    (bindChangedByOverride ? defaultRequireTLS(bind) : (raw.requireTLS ?? defaultRequireTLS(bind)));
  const token = overrides.token ?? raw.token ?? generateToken();
  return {
    port: overrides.port ?? raw.port ?? 7878,
    bind,
    token,
    allowedOrigins: overrides.allowedOrigins ?? raw.allowedOrigins ?? defaultAllowedOrigins,
    requireTLS,
    tlsCertPath: overrides.tlsCertPath ?? raw.tlsCertPath,
    tlsKeyPath: overrides.tlsKeyPath ?? raw.tlsKeyPath,
  };
}

export function defaultRequireTLS(bind: string): boolean {
  return !isLoopbackBind(bind);
}

export function isLoopbackBind(bind: string): boolean {
  const normalized = bind.trim().toLowerCase();
  return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1" || normalized === "[::1]";
}

function generateToken(): string {
  return crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "");
}
