import { appVersion } from "@prowl/protocol";
import { type DaemonConfig, loadConfigWithMetadata, rotateConfigToken } from "./auth/config";
import { createLogger, parseLogLevel } from "./logging/logger";
import { startServer } from "./server";

const args = new Map<string, string | boolean>();
for (let index = 2; index < Bun.argv.length; index += 1) {
  const arg = Bun.argv[index];
  if (!arg?.startsWith("--")) {
    continue;
  }
  const [key, inlineValue] = arg.slice(2).split("=", 2);
  if (!key) {
    continue;
  }
  const next = Bun.argv[index + 1];
  if (inlineValue) {
    args.set(key, inlineValue);
  } else if (next && !next.startsWith("--")) {
    args.set(key, next);
    index += 1;
  } else {
    args.set(key, true);
  }
}

if (args.has("help")) {
  process.stdout.write(`Usage:
  prowld
  prowld --port 7878
  prowld --bind 0.0.0.0
  prowld --tls-cert <path> --tls-key <path>
  prowld --print-token
  prowld --rotate-token
  prowld --log-level <debug|info|warn|error>
  prowld --version
`);
  process.exit(0);
}

if (args.has("version")) {
  process.stdout.write(`prowld ${appVersion}\n`);
  process.exit(0);
}

const overrides: Partial<DaemonConfig> = {};
if (args.has("port")) {
  overrides.port = Number(args.get("port"));
}
if (args.has("bind")) {
  overrides.bind = String(args.get("bind"));
}
if (args.has("tls-cert")) {
  overrides.tlsCertPath = String(args.get("tls-cert"));
}
if (args.has("tls-key")) {
  overrides.tlsKeyPath = String(args.get("tls-key"));
}
if (args.has("require-tls")) {
  overrides.requireTLS = true;
}
if (args.has("no-require-tls")) {
  overrides.requireTLS = false;
}

const logger = createLogger({ level: parseLogLevel(args.get("log-level")) });
const loadedConfig = await loadConfigWithMetadata(overrides);
const config = loadedConfig.config;

if (args.has("print-token")) {
  logger.info("printed daemon bearer token");
  process.stdout.write(`${config.token}\n`);
  process.exit(0);
}

if (args.has("rotate-token")) {
  const rotated = await rotateConfigToken(overrides);
  logger.warn("rotated daemon bearer token");
  process.stdout.write(`${rotated.token}\n`);
  process.exit(0);
}

startServer(config, { logger });
const scheme = config.tlsCertPath && config.tlsKeyPath ? "https" : "http";
if (loadedConfig.created) {
  process.stdout.write(`prowld token: ${config.token}\n`);
  logger.info("printed newly generated daemon bearer token");
}
process.stdout.write(`prowld listening on ${scheme}://${config.bind}:${config.port}\n`);
logger.info(`daemon listening on ${scheme}://${config.bind}:${config.port}`);
