# /cleanup


Remove every resource kstack has created in the cluster. The counterpart to [`/forget`](#forget), which clears local state.

**What it removes:** anything annotated `kstack.kubetail.com/owned-by=kstack` — ephemeral debug containers and privileged node-shell pods from [`/exec`](#exec), short-lived toolbox pods, and any temporary RBAC or ConfigMaps created to support them. Resources without the annotation are never touched, even if they live in the same namespace.

**How it works:** the agent lists everything it found, grouped by namespace and kind, and asks you to confirm before deleting. You can approve the whole set or tell it in natural language to skip specific items. If a delete fails — usually a finalizer or a permissions issue — the agent reports which resources remain and why, rather than retrying blindly.

**Safety:** `/cleanup` ships with `disable-model-invocation: true` — the agent never starts a cleanup on its own. It only runs when you type `/cleanup`, since it deletes cluster resources.

**Options:** none. Use the global `--context <ctx>` flag to target a different cluster.

**Reference:** [kstack.sh/reference/skills/cleanup](https://kstack.sh/reference/skills/cleanup)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

