# /audit-outdated


Outdated cluster components, known CVEs, and available version bumps. Looks for version drift across control plane, nodes, container images, Helm charts, CRDs, operators, and the API surface your manifests target.

**How it works:** runs the workflows in parallel against the Kubernetes API plus external indexes (release schedules, registries, Helm repos, Trivy DB, CVE feeds). Findings are de-duplicated by image digest so one outdated image shared across many pods doesn't dominate the report. CVE entries include severity and CISA KEV status when available — KEV hits rank above CVSS-high findings without known exploitation. "Drift within the supported window" is reported distinctly from "EOL" — the first is routine, the second is urgent. For registries outside the supported list, the skill says so rather than silently skipping the image.

**Arguments:**
- `<scope>` — natural-language scope (`images`, `cves in kube-system`). Optional — omit for a full sweep.

**Options:** none. Scope via natural language in the prompt or follow-ups.

**Reference:** [kstack.sh/reference/skills/audit-outdated](https://kstack.sh/reference/skills/audit-outdated)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

