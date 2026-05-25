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

export type LoadedDaemonConfig = {
  config: DaemonConfig;
  created: boolean;
};

const defaultBind = "127.0.0.1";
const defaultAllowedOrigins = ["http://localhost:5173", "http://127.0.0.1:5173"];

export function configPath(): string {
  return Bun.env.PROWL_CONFIG_PATH ?? join(homedir(), ".prowl", "config.json");
}

export async function loadConfig(overrides: Partial<DaemonConfig> = {}): Promise<DaemonConfig> {
  return (await loadConfigWithMetadata(overrides)).config;
}

export async function loadConfigWithMetadata(overrides: Partial<DaemonConfig> = {}): Promise<LoadedDaemonConfig> {
  const path = configPath();
  try {
    const raw = await readFile(path, "utf8");
    return {
      config: normalizeConfig(JSON.parse(raw) as Partial<DaemonConfig>, overrides),
      created: false,
    };
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
    return { config, created: true };
  }
}

export async function writeConfig(config: DaemonConfig): Promise<void> {
  const path = configPath();
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(config, null, 2)}\n`);
}

export async function rotateConfigToken(overrides: Partial<DaemonConfig> = {}): Promise<DaemonConfig> {
  const config = await loadConfig(overrides);
  const rotated = { ...config, token: generateToken() };
  await writeConfig(rotated);
  return rotated;
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
  const token = usableToken(overrides.token ?? raw.token);
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

export function hasUsableToken(token: string): boolean {
  return token.trim().length > 0;
}

function usableToken(token: string | undefined): string {
  return token && hasUsableToken(token) ? token : generateToken();
}

function generateToken(): string {
  return crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "");
}
