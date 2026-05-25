import { loadConfig } from "./auth/config";
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

if (args.has("version")) {
  process.stdout.write("prowld 0.0.0\n");
  process.exit(0);
}

const overrides: { port?: number; bind?: string } = {};
if (args.has("port")) {
  overrides.port = Number(args.get("port"));
}
if (args.has("bind")) {
  overrides.bind = String(args.get("bind"));
}

const config = await loadConfig(overrides);

if (args.has("print-token")) {
  process.stdout.write(`${config.token}\n`);
  process.exit(0);
}

startServer(config);
process.stdout.write(`prowld listening on ${config.bind}:${config.port}\n`);
