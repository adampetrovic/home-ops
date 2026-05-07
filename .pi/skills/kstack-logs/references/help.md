# /logs


An AI-powered log fetcher. Describe what you're looking for in natural language and the agent finds the right pods, picks the time window, and builds the grep filter to fetch only the lines that matter. The stream runs inside a **tmux** window that you and the agent are both attached to.

**How it works:** the agent translates your description into a Kubetail query, starts a detached tmux session (e.g. `kstack-logs-api-server`), tries to open a new terminal window attached to it, and prints the `tmux attach` command in chat as a fallback. You and the agent share the same pane — you can scroll, search, or watch the live tail; the agent reads conservatively to save tokens.

**Requirements:** `tmux` on the agent's `$PATH`, and Kubetail installed in the cluster (the skill offers to install it via Helm if missing).

**Arguments:**
- `<target>` — natural-language description of what to fetch (`api`, `errors from the last hour on api`, `checkout for "timeout" in last 15m`). Optional — the skill will prompt if omitted.

**Options:**
- `--attach` — attach the agent to an existing kstack tmux session instead of starting a new one
- `--detach` — start a new session detached (no terminal window opened, attach manually)

**Reference:** [kstack.sh/reference/skills/logs](https://kstack.sh/reference/skills/logs)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

