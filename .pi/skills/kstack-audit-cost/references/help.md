# /audit-cost


Resource waste and right-sizing recommendations. Looks for workloads that are over-provisioned, idle, or holding storage and load balancers nothing is using.

**How it works:** runs several workflows in parallel, joining `metrics-server` and Prometheus reads against the Kubernetes API for `Job`/`CronJob` status, PV/PVC binding, and `LoadBalancer` endpoints. Findings are ranked by potential impact (large requests-vs-usage gaps and idle workloads above unmounted PVCs and `Released` PVs), and only requests-vs-usage gaps large enough to matter in practice are flagged — small deltas are noise. The header always states the source (`metrics-server` for live, Prometheus for history) and the effective lookback so the reader can judge how much weight to give the recommendations.

**Arguments:**
- `<scope>` — natural-language scope (`requests`, `idle in staging`). Optional — omit for a full sweep.

**Options:** none. Scope via natural language in the prompt or follow-ups.

**Reference:** [kstack.sh/reference/skills/audit-cost](https://kstack.sh/reference/skills/audit-cost)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

