# Codemode Recipes

Submit each JavaScript block as raw codemode input, without markdown fences. These are read-only except the explicitly approved single-PR merge recipe. Adapt resource names from the repository. **Do not execute merge examples during skill editing/testing.**

## Runtime and failure handling

- QuickJS has no Node, filesystem, network, or timers. Use `tools.bash`, `tools.read`, and enabled web tools. Discover deferred tools via `searchTools()` / `describeTool()` before calling them.
- Use `Promise.allSettled()` for independent calls, normally four at a time. Await everything before the script ends; unfinished calls are cancelled.
- Bash resolves even on nonzero exit: inspect `exit_code`. Reject truncated JSON and parse failures. MCP calls also require checking `isError`.
- Set script deadlines longer than the combined batches' per-call deadlines. If output is truncated, retrieve exact necessary evidence from `full_output_path`; don't feed an omission marker into a parser.
- `store()` values must be small JSON (262144 characters per value; 1 MiB total). No functions, secrets, raw pod inventories, or complete release histories. Persist compact ledger/cache entries. Successful script completion is required for store writes to survive.
- Use separate codemode calls for decisions, approvals, each merge, and verification. Never let a mutation script throw after a confirmed mutation without emitting recovery details.

## Inventory: one request, compact output

```js
// @options: {"max_output_tokens": 2500, "timeout_ms": 60000}
const r = await tools.bash({
  command: "gh pr list --state open --limit 500 --json number,title,author,labels,body,files,headRefOid,isDraft",
  timeout: 45
});
if (r.exit_code !== 0 || r.truncated) throw new Error(r.output || "Incomplete PR inventory");
const all = JSON.parse(r.output);
if (all.length === 500) throw new Error("Inventory limit reached; paginate first");
// Verify the actual bot account/label conventions; labels alone are not proof of authorship.
const prs = all.filter(p => ["renovate", "renovate[bot]", "app/renovate"].includes(p.author?.login));
store("renovate.inventory", prs.map(p => ({
  number: p.number, title: p.title, sha: p.headRefOid, draft: p.isDraft,
  labels: p.labels.map(l => l.name), paths: p.files.map(f => f.path)
})));
// Bodies may be large; retrieve individual bodies later only when useful.
text(load("renovate.inventory"));
text({unclassifiedAuthors: [...new Set(all.filter(p => !prs.includes(p)).map(p => p.author?.login))]});
```

If the actual bot is missing from the allowlist, verify and amend it before proceeding. PR file lists can be capped by GitHub; use paginated PR-files API for unusually large updates.

## Bounded diff collection

```js
// @options: {"max_output_tokens": 6000, "timeout_ms": 300000}
const prs = load("renovate.inventory");
if (!prs) throw new Error("Run inventory first");
for (let i = 0; i < prs.length; i += 4) {
  const batch = prs.slice(i, i + 4);
  const results = await Promise.allSettled(batch.map(p => tools.bash({
    command: `gh pr diff ${Number(p.number)} --color never`, timeout: 45
  })));
  results.forEach((s, j) => {
    const p = batch[j];
    if (s.status !== "fulfilled") { text({pr:p.number, error:String(s.reason)}); return; }
    const r = s.value;
    if (r.exit_code !== 0 || r.truncated) {
      text({pr:p.number, error:"Incomplete diff", detail:r.output.slice(0, 500), path:r.full_output_path});
      return;
    }
    // Print small diffs verbatim, preserving context. Large diffs need targeted inspection.
    if (r.output.length > 16000) {
      text({pr:p.number, needsTargetedReview:true, paths:p.paths});
    } else text({pr:p.number, sha:p.sha, diff:r.output});
  });
}
```

For many PRs, run only selected inventory slices per script so the total evidence fits the output budget. Do not mark a PR reviewed solely because its diff command succeeded. Populate `renovate.plan` only after technical review.

## Deduplicated upstream evidence

Store verified requests as `renovate.releaseRequests`: `{key, repo, from, to}`. Deduplicate `key` (upstream + version range), batch four `gh api repos/<owner>/<repo>/releases --paginate` calls, check exit/truncation/parse errors, and select all releases in the range. Validate repo paths as `owner/repo` before shell interpolation. Semver ordering needs proper comparison, not lexical string sorting; non-semver tags need explicit review.

For already identified exact release tags, use this batched fetch (one request per unique upstream/tag). Build `renovate.releaseTags` from the full range identified above, with `{repo, tag}` entries. It does not discover skipped versions for you.

```js
// @options: {"max_output_tokens": 5000, "timeout_ms": 300000}
const requests = load("renovate.releaseTags") || [];
const unique = [...new Map(requests.map(x => [`${x.repo}@${x.tag}`, x])).values()];
const cache = load("renovate.releaseCache") || {};
const pending = unique.filter(x => !cache[`${x.repo}@${x.tag}`]);
for (let i = 0; i < pending.length; i += 4) {
  const batch = pending.slice(i, i + 4);
  const results = await Promise.allSettled(batch.map(x => {
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(x.repo)) throw new Error("Invalid upstream repo");
    const endpoint = `repos/${x.repo}/releases/tags/${encodeURIComponent(x.tag)}`;
    return tools.bash({command:`gh api '${endpoint}'`,timeout:45});
  }));
  results.forEach((s, j) => {
    const x = batch[j];
    if (s.status !== "fulfilled") { text({release:x,error:String(s.reason)}); return; }
    const r = s.value;
    if (r.exit_code !== 0 || r.truncated) { text({release:x,error:"Release unavailable/incomplete"}); return; }
    try {
      const release = JSON.parse(r.output);
      const body = release.body || "";
      if (!body || body.length > 18000) text({release:x,url:release.html_url,needsTargetedReview:true});
      else text({release:x,url:release.html_url,body});
    } catch (e) { text({release:x,error:String(e)}); }
  });
}
```

For many releases, slice requests across calls to stay within the total output budget. Cache only after review; use upstream/tag keys for tag evidence and upstream/range keys for combined compatibility findings.

Do not print whole release histories. Send selected bodies to `bulk_read` via temporary non-secret files for large evidence sets, or output bounded selected releases for direct review. A clipped body or missing intermediate release is incomplete evidence. Store **reviewed summaries** and URLs as `renovate.releaseCache`, not just the first lines of notes. Reuse evidence for paired chart/image PRs only when they genuinely share the same upstream release.

## Compact health snapshot

This recipe retains only issues and failures. Query warning events separately when diagnosing changes. Run at baseline and after each wave; changing the baseline requires an explicit operator decision, not overwriting it on every check.

```js
// @options: {"max_output_tokens": 3500, "timeout_ms": 120000}
const queries = [
  ["flux", "kubectl get helmreleases.helm.toolkit.fluxcd.io,kustomizations.kustomize.toolkit.fluxcd.io -A -o json"],
  ["pods", "kubectl get pods -A -o json"],
  ["nodes", "kubectl get nodes -o json"],
  ["alerts", "kubectl exec -n observability svc/kube-prometheus-stack-alertmanager -- wget -qO- 'http://localhost:9093/api/v2/alerts?silenced=false&inhibited=false&active=true'"]
];
const results = await Promise.allSettled(queries.map(([,command]) => tools.bash({command,timeout:60})));
const issues = [], errors = [];
const id = x => `${x.kind || "Pod"}/${x.metadata.namespace || "cluster"}/${x.metadata.name}`;
for (let i = 0; i < results.length; i++) {
  const name = queries[i][0], s = results[i];
  try {
    if (s.status !== "fulfilled") throw new Error(String(s.reason));
    const r = s.value;
    if (r.exit_code !== 0 || r.truncated) throw new Error(r.output.slice(0, 500) || "Incomplete response");
    const data = JSON.parse(r.output);
    if (name === "alerts") {
      for (const a of data) if (a.labels.alertname !== "Watchdog") {
        const labels = Object.keys(a.labels).sort().map(k => `${k}=${a.labels[k]}`).join(",");
        issues.push({key:`alert/${labels}`, detail:a.annotations?.summary || ""});
      }
      continue;
    }
    if (!Array.isArray(data.items) || data.items.length === 0) throw new Error(`Empty/invalid ${name} inventory`);
    for (const x of data.items) {
      const st = x.status || {}, conditions = st.conditions || [];
      if (name === "flux") {
        const ready = conditions.find(c => c.type === "Ready");
        const observed = ready?.observedGeneration ?? st.observedGeneration;
        if (x.spec?.suspend || ready?.status !== "True" || observed !== x.metadata.generation)
          issues.push({key:id(x), detail:{suspended:x.spec?.suspend,ready,observed,generation:x.metadata.generation}});
      } else if (name === "nodes") {
        if (x.spec?.unschedulable || conditions.find(c => c.type === "Ready")?.status !== "True")
          issues.push({key:id(x),detail:{unschedulable:x.spec?.unschedulable,conditions}});
      } else {
        if (st.phase === "Succeeded") continue;
        const cs = [...(st.initContainerStatuses || []), ...(st.containerStatuses || [])];
        const waiting = cs.filter(c => c.state?.waiting).map(c => ({name:c.name,...c.state.waiting}));
        if (st.phase !== "Running" || x.metadata.deletionTimestamp || conditions.find(c => c.type === "Ready")?.status !== "True" || waiting.length)
          issues.push({key:id(x),detail:{phase:st.phase,terminating:x.metadata.deletionTimestamp,waiting}});
      }
    }
  } catch (e) { errors.push({check:name,error:String(e)}); }
}
const snapshot = {at:new Date().toISOString(),issues,errors};
store("renovate.healthLatest", snapshot);
const baseline = load("renovate.baseline");
const previous = new Set((baseline?.issues || []).map(x => x.key));
text({at:snapshot.at,errors,issues:issues.filter(x => !baseline || !previous.has(x.key)),
  preexisting:issues.filter(x => previous.has(x.key)).map(x => x.key)});
```

After inspecting the initial snapshot, save `store("renovate.baseline", load("renovate.healthLatest"))` in a separate successful call. This snapshot **does not prove revision convergence or target versions**; run targeted Flux source/status and workload checks as the playbook requires. Ceph, backup activity, Talos versions, and BGP/LoadBalancer checks are additional component-specific reads.

## Approved single-PR merge

Choose the next PR manually from the approved wave after its barrier has passed. The approval record is `{number, sha}` tied to the actual user reply. Replace `1234` with that selected number; do not execute this example literally.

```js
// @options: {"max_output_tokens": 1500, "timeout_ms": 180000}
const number = 1234;
const approval = (load("renovate.approved") || []).find(x => x.number === number);
if (!approval || !/^[a-f0-9]{40}$/.test(approval.sha)) throw new Error("No reviewed SHA approval");
const r = await tools.bash({command:`gh pr view ${number} --json state,headRefOid,isDraft,mergeable`,timeout:30});
if (r.exit_code !== 0 || r.truncated) throw new Error("PR precheck failed");
const p = JSON.parse(r.output);
if (p.state !== "OPEN" || p.isDraft || p.mergeable !== "MERGEABLE" || p.headRefOid !== approval.sha)
  throw new Error("PR changed or is not mergeable; stop and re-review");
const result = await tools.bash({
  command:`gh pr merge ${number} --rebase --delete-branch --match-head-commit ${approval.sha}`,timeout:90
});
// Do not throw after mutation: persist uncertainty for recovery on the next call.
const entry = {number,sha:approval.sha,at:new Date().toISOString(),
  commandSucceeded:result.exit_code === 0,needsVerification:true,detail:result.output.slice(0,1000)};
store("renovate.ledger", [...(load("renovate.ledger") || []),entry]);
text(entry);
```

In the **next** call, query `gh pr view <number> --json state,mergedAt,mergeCommit,headRefOid`, confirm MERGED and the reviewed head, and update the ledger with merge commit/time. If a tool rejects or the script is interrupted during mutation, query PR state before any retry; ledger absence does not mean no merge happened. Only then select another PR, or begin the wave's reconciliation barrier.

## Resume and finish

On resume, inspect stored plan/approval/ledger and refresh uncertain PR states and cluster health. Store timestamps and SHA-bound evidence; never reuse an old health check as current proof. Verify previously merged PRs before continuing. Fetch with `jj git fetch`, preserve unrelated local work, and inventory remaining Renovate PRs using the same ownership filter as discovery.
