import type { TaskStatus } from "$lib/state/types";

const promptReadyPatterns = [/^\s*[$%#❯>]\s*$/m, /tokens used/i, /done|complete|finished/i];
const runningPatterns = [/thinking|running|working|executing/i];

export function detectAgentTaskStatus(buffer: string): TaskStatus {
  const tail = buffer.slice(-4096);
  if (runningPatterns.some((pattern) => pattern.test(tail))) {
    return "running";
  }
  if (promptReadyPatterns.some((pattern) => pattern.test(tail))) {
    return "done";
  }
  return "idle";
}
