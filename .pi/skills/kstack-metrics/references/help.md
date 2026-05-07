# /metrics


An AI-powered metrics fetcher. Describe what you want to see and the agent resolves the right target, picks a sensible time window, and returns a compact summary. Read-only and never mutates cluster state.

**How it works:** the agent translates your description into a query against whichever source fits (`metrics-server` or Prometheus), reports summary statistics (p50, p95, max) rather than piping the full series through the model, and shows the resolved query before running it when the scope looks broader than intended. For *why* a metric moved, it hands off to [`/logs`](#logs); for root-cause context, [`/investigate`](#investigate); for a full right-sizing sweep, [`/audit-cost`](#audit-cost).

**Arguments:**
- `<target>` — natural-language description (`api`, `memory on checkout last 1h`, `top pods by cpu in payments`). Optional — the skill will prompt if omitted.

**Options:** none. Scope the target, metric, and time window via natural language in the prompt or follow-ups.

**Reference:** [kstack.sh/reference/skills/metrics](https://kstack.sh/reference/skills/metrics)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

