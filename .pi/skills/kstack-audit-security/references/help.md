# /audit-security


RBAC review, pod security posture, and privilege-tightening recommendations. Looks for over-privileged identities and workloads — `ServiceAccounts` with more access than they use, pods running as root or with host-level escapes, and bindings that grant cluster-wide power where a namespace-scoped role would do.

**How it works:** queries the Kubernetes API only; no exec, no log access. Findings are ranked by blast radius (cluster-scoped wildcards above namespace-scoped ones, host escapes above missing seccomp). RBAC checks are **static** — they find what `Roles` grant, not what subjects actually use; detecting truly unused permissions requires audit-log analysis, which this skill does not do. `Secrets` are referenced by name, namespace, and type only — contents are never read.

**Arguments:**
- `<scope>` — natural-language scope (`rbac`, `pods in kube-system`). Optional — omit for a full sweep.

**Options:** none. Scope via natural language in the prompt or follow-ups.

**Reference:** [kstack.sh/reference/skills/audit-security](https://kstack.sh/reference/skills/audit-security)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

