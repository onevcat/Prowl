import { renderList } from "./commands/list";
import { renderVersion } from "./commands/version";

const [, , command = "help", ...args] = Bun.argv;

switch (command) {
  case "list":
    process.stdout.write(`${renderList()}\n`);
    break;
  case "version":
  case "--version":
    process.stdout.write(`${renderVersion()}\n`);
    break;
  case "send":
    process.stdout.write(`send ${args[0] ?? ""}: ${args.slice(1).join(" ")}\n`);
    break;
  case "read":
    process.stdout.write(`read ${args[0] ?? ""}\n`);
    break;
  case "help":
  case "--help":
    process.stdout.write(`Usage:
  prowl list
  prowl send <paneId> "<command>"
  prowl read <paneId>
  prowl key <paneId> <keystroke>
  prowl new --worktree <id> [--command]
  prowl close <paneId>
  prowl worktree list [--repo <id>]
  prowl repo list
  prowl daemon start|stop|status
  prowl version
`);
    break;
  default:
    process.stderr.write(`Unknown command: ${command}\n`);
    process.exit(64);
}
