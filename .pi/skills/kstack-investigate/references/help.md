# /investigate


Kick off a root-cause investigation on a failing or suspicious resource. When the skill is invoked, it runs a script to gather an initial data bundle and briefs the agent. From there, you can ask follow-up questions in natural language and the agent decides whether to answer from what it has, fetch something new, or reach for another tool.

**What it gathers:** spec and status of the problematic resources; events on those resources and their owners (a `Pod`'s `ReplicaSet` and `Deployment`, a `Job`'s `CronJob`, etc.); logs from current and previous containers, truncated to the lines most likely to contain the failure; obvious related resources (backing `Service`, mounted `ConfigMap`/`Secret` names, bound `PVC`s, referenced `ServiceAccount`); and the node the pods are scheduled on when relevant.

**How it works:** the skill loads the bundle from the Kubernetes API and briefs the agent on how to read it (exit codes, event reasons, common state combinations), when follow-ups should re-fetch rather than reason from the stale bundle, and when to hand off to [`/logs`](#logs), [`/exec`](#exec), or [`/metrics`](#metrics).

**Arguments:**
- `<target>` — `<kind>/<name>` (e.g. `pod/checkout-7c9`) or natural language (`the api deployment`, `why is checkout crashing`). Optional — the skill will prompt if omitted.

**Options:** none. Scope logs, time windows, or resources via natural language in the prompt or follow-ups.

**Reference:** [kstack.sh/reference/skills/investigate](https://kstack.sh/reference/skills/investigate)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

