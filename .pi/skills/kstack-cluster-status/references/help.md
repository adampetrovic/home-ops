# /cluster-status


A dense health snapshot of the cluster — node conditions, pod aggregates, and a ranked list of the issues that actually matter.

**What it checks:** cluster identity (context, Kubernetes version, platform), node `Ready`/`MemoryPressure`/`DiskPressure`/`PIDPressure` conditions and `SchedulingDisabled`, control-plane vs. worker split, pod phase and `Ready` across all namespaces, pods with non-zero restart counts, and a ranked top-issues list (top 5 by severity).

**How it works:** fans out `kubectl version`, `kubectl get nodes -o json`, and `kubectl get pods -A -o json` in parallel, writing each to a per-context cache (`cluster.json`, `nodes.json`, `pods.json`). Aggregation and severity ranking happen client-side. Follow-up questions ("list pods", "pods on <node>", "which nodes are tainted") are answered by reading the cache with `jq` rather than re-invoking the skill.

**Options:**
- `--refresh` — fetch most recent data, bypassing and refreshing the cache (default: `false`)
- `--ttl <duration>` — only update the cache if older than `<duration>` (default: `15m`)

**Reference:** [kstack.sh/reference/skills/cluster-status](https://kstack.sh/reference/skills/cluster-status)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

