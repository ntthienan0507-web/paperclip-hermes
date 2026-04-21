import type { AdapterExecutionContext, AdapterExecutionResult } from "@paperclipai/adapter-utils";
import {
  asString,
  asNumber,
  parseObject,
  buildPaperclipEnv,
  runChildProcess,
  buildInvocationEnvForLogs,
} from "@paperclipai/adapter-utils/server-utils";

// Paperclip env vars to forward into the container via docker exec -e
const FORWARDED_ENV_VARS = [
  "PAPERCLIP_API_KEY",
  "PAPERCLIP_AGENT_ID",
  "PAPERCLIP_COMPANY_ID",
  "PAPERCLIP_API_URL",
  "PAPERCLIP_RUN_ID",
  "PAPERCLIP_TASK_ID",
] as const;

export async function execute(ctx: AdapterExecutionContext): Promise<AdapterExecutionResult> {
  const { runId, agent, config, context, onLog, onMeta, onSpawn } = ctx;

  const container = asString(config.container, "hermes-orch");
  const script = asString(config.script, "auto-dispatch.sh");
  const model = asString(config.model, "qwen/qwen3-coder");
  const timeoutSec = asNumber(config.timeoutSec, 300);
  const graceSec = asNumber(config.graceSec, 10);

  // Build env from Paperclip context
  const paperclipEnv = buildPaperclipEnv(agent);
  const envConfig = parseObject(config.env);
  const env: Record<string, string> = { ...paperclipEnv };
  env.PAPERCLIP_RUN_ID = runId;

  // Forward task/issue context
  const wakeTaskId =
    (typeof context.taskId === "string" && context.taskId.trim().length > 0 && context.taskId.trim()) ||
    (typeof context.issueId === "string" && context.issueId.trim().length > 0 && context.issueId.trim()) ||
    null;
  if (wakeTaskId) env.PAPERCLIP_TASK_ID = wakeTaskId;

  // Merge user-configured env
  for (const [key, value] of Object.entries(envConfig)) {
    if (typeof value === "string") env[key] = value;
  }

  // Override LLM model
  env.LLM_MODEL = model;

  // Build docker exec args: -e flags for env forwarding
  const dockerArgs: string[] = ["exec", "-i"];
  for (const varName of FORWARDED_ENV_VARS) {
    if (env[varName]) {
      dockerArgs.push("-e", `${varName}=${env[varName]}`);
    }
  }
  // Forward LLM model and adapter URL
  dockerArgs.push("-e", `LLM_MODEL=${model}`);
  if (env.ADAPTER_URL) {
    dockerArgs.push("-e", `ADAPTER_URL=${env.ADAPTER_URL}`);
  }
  // Forward OPENROUTER_API_KEY if set (read from container env if not)
  if (env.OPENROUTER_API_KEY) {
    dockerArgs.push("-e", `OPENROUTER_API_KEY=${env.OPENROUTER_API_KEY}`);
  }

  dockerArgs.push(container, "bash", `/root/${script}`);

  const loggedEnv = buildInvocationEnvForLogs(env, {
    runtimeEnv: { ...process.env, ...env },
    resolvedCommand: "docker",
  });

  if (onMeta) {
    await onMeta({
      adapterType: "hermes_local",
      command: "docker",
      cwd: process.cwd(),
      commandArgs: dockerArgs,
      commandNotes: [`Executing ${script} in container ${container}`],
      env: loggedEnv,
      prompt: `Script: ${script}, Model: ${model}`,
      context,
    });
  }

  const proc = await runChildProcess(runId, "docker", dockerArgs, {
    cwd: process.cwd(),
    env: Object.fromEntries(
      Object.entries({ ...process.env, ...env }).filter(
        (entry): entry is [string, string] => typeof entry[1] === "string",
      ),
    ),
    timeoutSec,
    graceSec,
    onSpawn,
    onLog,
  });

  if (proc.timedOut) {
    return {
      exitCode: proc.exitCode,
      signal: proc.signal,
      timedOut: true,
      errorMessage: `Timed out after ${timeoutSec}s`,
    };
  }

  const success = (proc.exitCode ?? 0) === 0;
  const stderrLine = proc.stderr
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean) ?? "";

  return {
    exitCode: proc.exitCode,
    signal: proc.signal,
    timedOut: false,
    errorMessage: success ? null : stderrLine || `Hermes exited with code ${proc.exitCode ?? -1}`,
    provider: "openrouter",
    model,
    resultJson: {
      stdout: proc.stdout,
      stderr: proc.stderr,
    },
    summary: extractSummary(proc.stdout),
  };
}

/** Extract meaningful summary from script output */
function extractSummary(stdout: string): string {
  const lines = stdout.split("\n").filter((l) => l.startsWith("[orch]") || l.startsWith("[wiki-orch]"));
  return lines.slice(-5).join("\n") || stdout.slice(-500);
}
