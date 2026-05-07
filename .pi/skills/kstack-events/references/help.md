# /events


Recent cluster events, grouped by reason and ranked by severity so the signal isn't drowned in `Pulled`/`Created`/`Started` noise.

**What it checks:** `Warning` events across all namespaces, grouped by `(reason, involvedObject.kind, namespace)`; notable `Normal` events (`Killing`, `Preempting`, `NodeNotReady`, `Rebooted`, `FailedScheduling`) with chatty reasons (`Pulled`, `Created`, `Started`, `Scheduled`, `SuccessfulCreate`) collapsed into a tail line. Each group includes count, first/last timestamp, the most recent message, and the involved objects.

**How it works:** a single `kubectl get events --all-namespaces` call (against `events.k8s.io/v1`, sorted server-side by `lastTimestamp`), written to a per-context cache as `events.json`. Aggregation and ranking happen client-side. Follow-ups ("only payments", "events on pod/checkout-7c9", "show suppressed") are answered by reading the cache with `jq` — and walk owners one level up (`Pod` → `ReplicaSet` → `Deployment`) so controller-fired events aren't missed.

**Options:**
- `--refresh` — fetch most recent data, bypassing and refreshing the cache (default: `false`)
- `--ttl <duration>` — only update the cache if older than `<duration>` (default: `5m`)

**Reference:** [kstack.sh/reference/skills/events](https://kstack.sh/reference/skills/events)


**Global flags** (supported by every skill):

| Flag              | Description                                                              |
|-------------------|--------------------------------------------------------------------------|
| `--context <ctx>` | Override the current kubeconfig context                                  |
| `--namespace <n>` | Scope the run to a single namespace (defaults to all accessible)         |
| `--json`          | Emit structured output for piping into other tools                       |
| `--help`          | Open the reference documentation for the skill in your browser           |

