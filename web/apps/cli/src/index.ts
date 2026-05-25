import { renderList } from "./commands/list";
import { renderRepoList } from "./commands/repo";
import { renderVersion } from "./commands/version";
import { renderWorktreeCreate, renderWorktreeList } from "./commands/worktree";

const [, , command = "help", ...args] = Bun.argv;

switch (command) {
  case "list":
    process.stdout.write(`${await renderList()}\n`);
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
  case "repo":
    if (args[0] === "list") {
      process.stdout.write(`${await renderRepoList()}\n`);
      break;
    }
    process.stderr.write(`Unknown repo command: ${args[0] ?? ""}\n`);
    process.exit(64);
    break;
  case "worktree":
    if (args[0] === "list") {
      const repoIndex = args.indexOf("--repo");
      process.stdout.write(`${await renderWorktreeList(repoIndex === -1 ? undefined : args[repoIndex + 1])}\n`);
      break;
    }
    if (args[0] === "create") {
      process.stdout.write(`${await renderWorktreeCreate(args[1], args[2])}\n`);
      break;
    }
    process.stderr.write(`Unknown worktree command: ${args[0] ?? ""}\n`);
    process.exit(64);
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
