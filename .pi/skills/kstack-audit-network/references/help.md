# /audit-network


NetworkPolicy, Service, Ingress, Gateway API, DNS, and encryption sanity checks. Looks for broken or missing pieces in cluster networking such as `NetworkPolicy` instances that don't match anything, `Services` with no endpoints, `Ingress` and Gateway API routes that won't resolve, DNS problems, and workloads talking in plaintext when a mesh is available.

**How it works:** queries the Kubernetes API plus CoreDNS metrics and mesh CRDs when present. TLS checks distinguish "Secret contents not readable due to RBAC" from "expired" rather than reporting false positives. Findings are grouped by workflow and include the evidence (selectors, endpoints, ConfigMap keys), not just the verdict.

**Arguments:**
- `<scope>` — natural-language scope (`policies`, `ingress in prod`). Optional — omit for a full sweep.

**Options:** none. Scope via natural language in the prompt or follow-ups.

**Reference:** [kstack.sh/reference/skills/audit-network](https://kstack.sh/reference/skills/audit-network)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

