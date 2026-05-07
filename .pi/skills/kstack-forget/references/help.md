# /forget


Wipe kstack's local state on your machine. Over time kstack builds up a working memory of your clusters — recent query results, detected integrations, resource fingerprints, and baselines it uses to detect anomalies. This skill forces a clean slate. It does not touch the cluster itself; for that, see [`/cleanup`](#cleanup).

**What it clears:** state lives under `~/.config/kstack/`, partitioned per kubeconfig context.
- **Cache** (`~/.config/kstack/cache/<context>/`) — recent query results, log buffers, dedup tables, in-flight watcher state. Cheap to rebuild; cleared freely.
- **Learned state** (`~/.config/kstack/state/<context>/`) — detected integrations, resource fingerprints, baselines, per-cluster preferences. Rebuilt on next use, but may take a few interactions to fully re-form.

**How it works:** by default clears both cache and learned state for the current kubeconfig context — forgetting `staging` never affects `prod`. Use the global `--context <ctx>` flag to target a different cluster. Run it after a cluster is rebuilt or migrated (so kstack stops trusting stale fingerprints), when baselines feel stale, when an earlier session taught it something wrong, or when you're handing the machine off and want no cluster-specific state left behind.

**Safety:** `/forget` ships with `disable-model-invocation: true` — the agent never wipes local state on its own. It only runs when you type `/forget`, so cached context isn't lost unexpectedly.

**Options:**
- `--all` — Clear cache and learned state for every context, not just the current one.

**Reference:** [kstack.sh/reference/skills/forget](https://kstack.sh/reference/skills/forget)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

