import { loadConfig } from "../apps/daemon/src/auth/config";

const daemonPort = Number(Bun.env.PROWL_DAEMON_PORT ?? 7878);
const webPort = Number(Bun.env.PROWL_WEB_PORT ?? 5173);
const daemonURL = `ws://127.0.0.1:${daemonPort}/ws`;
const webURL = new URL(`http://127.0.0.1:${webPort}/`);
const config = await loadConfig({ port: daemonPort, bind: "127.0.0.1", requireTLS: false });
webURL.searchParams.set("token", config.token);
if (daemonPort !== 7878) {
  webURL.searchParams.set("daemon", daemonURL);
}

process.stdout.write(`prowld token: ${config.token}\n`);
process.stdout.write(`web url: ${webURL.toString()}\n`);

const children = [
  start("daemon", ["bun", "run", "apps/daemon/src/index.ts", "--port", String(daemonPort), "--bind", "127.0.0.1"]),
  start("web", ["bun", "run", "--filter", "@prowl/web", "dev", "--", "--port", String(webPort)]),
];

let shuttingDown = false;
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    shutdown(0);
  });
}

await Promise.race(
  children.map(async ({ name, process: child }) => {
    const exitCode = await child.exited;
    if (!shuttingDown) {
      process.stderr.write(`${name} exited with ${exitCode}\n`);
      shutdown(exitCode ?? 1);
    }
  }),
);

function start(name: string, command: string[]): { name: string; process: Bun.Subprocess<"ignore", "pipe", "pipe"> } {
  const child = Bun.spawn(command, {
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...Bun.env,
      PROWL_DAEMON_URL: daemonURL,
    },
  });
  void pipe(name, child.stdout);
  void pipe(name, child.stderr);
  return { name, process: child };
}

async function pipe(name: string, stream: ReadableStream<Uint8Array>): Promise<void> {
  const decoder = new TextDecoder();
  for await (const chunk of stream) {
    for (const line of decoder.decode(chunk).split(/\r?\n/)) {
      if (line) {
        process.stdout.write(`[${name}] ${line}\n`);
      }
    }
  }
}

function shutdown(exitCode: number): never {
  shuttingDown = true;
  for (const child of children) {
    child.process.kill();
  }
  process.exit(exitCode);
}
