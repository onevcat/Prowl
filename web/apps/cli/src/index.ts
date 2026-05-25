import {
  daemonStart,
  daemonStatus,
  daemonStop,
  renderDaemonStart,
  renderDaemonStatus,
  renderDaemonStop,
} from "./commands/daemon";
import { getPaneList, renderList } from "./commands/list";
import {
  closePane,
  closePaneResult,
  createPane,
  readPane,
  renderPaneNew,
  renderPaneRead,
  sendPaneCommandWithOptions,
  sendPaneKey,
  sendPaneKeyResult,
} from "./commands/pane";
import {
  addRepository,
  getRepositoryList,
  removeRepository,
  renderRepoAdd,
  renderRepoList,
  renderRepoRemove,
} from "./commands/repo";
import { renderVersion } from "./commands/version";
import {
  createWorktree,
  getWorktreeDiff,
  getWorktreeList,
  renderWorktreeCreate,
  renderWorktreeDiff,
  renderWorktreeList,
} from "./commands/worktree";

const rawArgs = Bun.argv.slice(2);
const json = rawArgs.includes("--json");
const [command = "help", ...args] = rawArgs.filter((arg) => arg !== "--json");

switch (command) {
  case "list":
    await writeOutput(() => getPaneList(), renderList);
    break;
  case "version":
  case "--version":
    writeValue({ name: "prowl", version: "0.0.0" }, renderVersion());
    break;
  case "send":
    {
      const capture = args.includes("--capture");
      const sendArgs = args.filter((arg) => arg !== "--capture");
      const paneId = sendArgs[0];
      const commandText = sendArgs.slice(1).join(" ");
      const result = await sendPaneCommandWithOptions(paneId, commandText, { capture });
      writeValue(result, result.output ?? `sent\t${result.paneId}`);
    }
    break;
  case "read":
    await writeOutput(
      () => readPane(args[0]),
      () => renderPaneRead(args[0]),
    );
    break;
  case "key":
    await writeOutput(
      () => sendPaneKeyResult(args[0], args[1]),
      () => sendPaneKey(args[0], args[1]),
    );
    break;
  case "new":
    await writeOutput(
      () => createPane(args),
      () => renderPaneNew(args),
    );
    break;
  case "close":
    await writeOutput(
      () => closePaneResult(args[0]),
      () => closePane(args[0]),
    );
    break;
  case "repo":
    if (args[0] === "list") {
      await writeOutput(() => getRepositoryList(), renderRepoList);
      break;
    }
    if (args[0] === "add") {
      await writeOutput(
        () => addRepository(args[1]),
        () => renderRepoAdd(args[1]),
      );
      break;
    }
    if (args[0] === "remove") {
      await writeOutput(
        () => removeRepository(args[1]),
        () => renderRepoRemove(args[1]),
      );
      break;
    }
    process.stderr.write(`Unknown repo command: ${args[0] ?? ""}\n`);
    process.exit(64);
    break;
  case "worktree":
    if (args[0] === "list") {
      const repoIndex = args.indexOf("--repo");
      const repoId = repoIndex === -1 ? undefined : args[repoIndex + 1];
      await writeOutput(
        () => getWorktreeList(repoId),
        () => renderWorktreeList(repoId),
      );
      break;
    }
    if (args[0] === "create") {
      await writeOutput(
        () => createWorktree(args[1], args[2]),
        () => renderWorktreeCreate(args[1], args[2]),
      );
      break;
    }
    if (args[0] === "diff") {
      await writeOutput(
        () => getWorktreeDiff(args[1]),
        () => renderWorktreeDiff(args[1]),
      );
      break;
    }
    process.stderr.write(`Unknown worktree command: ${args[0] ?? ""}\n`);
    process.exit(64);
    break;
  case "daemon":
    if (args[0] === "start") {
      await writeOutput(daemonStart, renderDaemonStart);
      break;
    }
    if (args[0] === "stop") {
      await writeOutput(daemonStop, renderDaemonStop);
      break;
    }
    if (args[0] === "status") {
      await writeOutput(daemonStatus, renderDaemonStatus);
      break;
    }
    process.stderr.write(`Unknown daemon command: ${args[0] ?? ""}\n`);
    process.exit(64);
    break;
  case "help":
  case "--help":
    process.stdout.write(`Usage:
  prowl list
  prowl send <paneId> "<command>" [--capture]
  prowl read <paneId>
  prowl key <paneId> <keystroke>
  prowl new --worktree <id> [--command]
  prowl close <paneId>
  prowl worktree list [--repo <id>]
  prowl worktree create <repoId> <branch>
  prowl worktree diff <worktreeId>
  prowl repo list
  prowl repo add <path>
  prowl repo remove <repoId>
  prowl daemon start|stop|status
  prowl version
`);
    break;
  default:
    process.stderr.write(`Unknown command: ${command}\n`);
    process.exit(64);
}

async function writeOutput(value: () => Promise<unknown>, render: () => Promise<string>): Promise<void> {
  if (json) {
    writeValue(await value());
    return;
  }
  process.stdout.write(`${await render()}\n`);
}

function writeValue(value: unknown, text?: string): void {
  process.stdout.write(`${json ? JSON.stringify(value) : text}\n`);
}
