# /exec


An AI-powered version of `kubectl exec`. Describe the target in natural language and the agent picks the right mechanism: a normal `exec` into a running container, an ephemeral debug container when the target has no usable shell, or a privileged shell on a node. The session runs inside a **tmux** window that you and the agent are both attached to — either of you can type, both see the output.

**How it works:** the agent starts a detached tmux session (e.g. `kstack-exec-api-server`), tries to open a new terminal window attached to it, and prints the `tmux attach` command in chat as a fallback. The agent reads from the pane conservatively to save tokens. Tell it to tear down and it kills the tmux session and deletes any pod it created.

**Requirements:** `tmux` on the agent's `$PATH`.

**Safety:** `/exec` ships with `disable-model-invocation: true` — the agent never starts a shell on its own. It only runs when you type `/exec`, deliberately, given the privileged modes above.

**Arguments:**
- `<target>` — natural-language description (`api`, `api/sidecar`, `node worker-3`, `debug api`). Optional — the skill will prompt if omitted.

**Options:**
- `--image <image>` — image to use for node and debug-container modes (default `netshoot`)
- `--attach` — attach the agent to an existing kstack tmux session instead of starting a new one
- `--detach` — start a new session detached (no terminal window opened, attach manually)

**Reference:** [kstack.sh/reference/skills/exec](https://kstack.sh/reference/skills/exec)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

