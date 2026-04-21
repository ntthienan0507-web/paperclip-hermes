export const type = "hermes_local";
export const label = "Hermes (Docker container)";

export const models = [
  { id: "qwen/qwen3-coder", label: "Qwen3 Coder (OpenRouter)" },
  { id: "qwen/qwen3-coder:free", label: "Qwen3 Coder Free (OpenRouter)" },
];

export const agentConfigurationDoc = `# hermes_local agent configuration

Adapter: hermes_local

Runs Hermes agents inside Docker containers via \`docker exec\`.
Supports orchestrator (auto-dispatch) and wiki-trainer (auto-dispatch-wiki) roles.

Core fields:
- container (string, required): Docker container name to exec into (e.g. "hermes-orch")
- script (string, optional): dispatch script to run inside container (default: "auto-dispatch.sh")
  - "auto-dispatch.sh" — standard orchestrator: analyze issue → create sub-issues → dispatch batch
  - "auto-dispatch-wiki.sh" — wiki-trainer: analyze issue → create wiki generation sub-issues → dispatch
- model (string, optional): LLM model for analysis (default: "qwen/qwen3-coder")
- env (object, optional): KEY=VALUE environment variables passed to docker exec

Operational fields:
- timeoutSec (number, optional): run timeout in seconds (default: 300)

Notes:
- Paperclip env vars (PAPERCLIP_API_KEY, PAPERCLIP_AGENT_ID, etc.) are auto-forwarded to the container.
- The container must be running and accessible via \`docker exec\`.
- SSH keys and GitLab tokens should be mounted in the container at build time.
- Script output is streamed back as adapter logs.
`;
