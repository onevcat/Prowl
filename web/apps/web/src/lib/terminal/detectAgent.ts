import type { TaskStatus } from "$lib/state/types";

const promptReadyPatterns = [/^\s*[$%#❯>]\s*$/m, /tokens used/i, /\b(done|complete|finished)\b/i];
const runningPatterns = [/thinking|running|working|executing/i];
const failedPatterns = [/\b(failed|exception)\b/i, /\b(fatal error|error:)\b/i];

export function detectAgentTaskStatus(buffer: string): TaskStatus {
  return inferAgentTaskStatus(buffer) ?? "idle";
}

export function inferAgentTaskStatus(buffer: string): TaskStatus | null {
  const tail = buffer.slice(-4096);
  if (failedPatterns.some((pattern) => pattern.test(tail))) {
    return "failed";
  }
  if (promptReadyPatterns.some((pattern) => pattern.test(tail))) {
    return "done";
  }
  if (runningPatterns.some((pattern) => pattern.test(tail))) {
    return "running";
  }
  return null;
}
