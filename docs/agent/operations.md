# Agent Operations

Read this before creating commits, opening/updating PRs, running Flux/debug commands, or doing post-merge cleanup.

## Jujutsu Workflow

This repo uses Jujutsu (`jj`) with a Git backend. Use `jj` commands instead of `git`.

Commit descriptions should include a concise one-line rationale in the body where useful, especially for `fix:` and `chore:` changes:

```text
fix(observability): stop alerting on Talos kernel log patterns

Why: keep paging signals symptom-based instead of brittle cause-based log regexes
```

Prefer change IDs when referencing revisions. Use `jj diff --git` for reviewable diffs.

## Task Automation

Run tasks with `task <namespace>:<task>`.

Talos operations:

```bash
task talos:generate
task talos:apply
task talos:upgrade node=<ip>
task talos:upgrade-rollout
task talos:upgrade-k8s node=<ip> to=<version>
task talos:fetch-kubeconfig
```

Kubernetes:

```bash
task k8s:delete-failed-pods
```

VolSync:

```bash
task volsync:list app=<name> ns=<namespace>
task volsync:snapshot app=<name> ns=<namespace>
task volsync:restore app=<name> ns=<namespace>
task volsync:restore-r2 app=<name> ns=<namespace>
task volsync:restore-r2-fallback app=<name> ns=<namespace> capacity=<size>
task volsync:unlock app=<name> ns=<namespace>
```

## GitOps Reconciliation

Flux reconciles cluster state from Git. A GitHub webhook notifies Flux on every push to `main`, triggering reconciliation quickly.

`install.remediation.retries: -1` means a failing new install keeps retrying until a corrected spec is pushed.

Manual reconciliation when needed:

```bash
flux reconcile ks <app-name> -n flux-system --with-source
```

## Pull Request CI Checks

CI checks are useful validation but are not a default merge gate. Do not wait for checks before merging unless the user explicitly asks.

Key checks:

- `Flux Local - Test` renders HelmReleases/Kustomizations and validates output.
- `Flux Local - Diff` shows rendered diff against main.

Optional status check:

```bash
gh pr checks <pr-number>
```

If you choose to wait and checks fail, inspect with:

```bash
gh run view <run-id> --log-failed
```

Then fix and push again.

## Debugging Applications

Common read-only checks:

```bash
kubectl get ks -A
kubectl get hr -A
flux get kustomization --all-namespaces
kubectl describe hr <name> -n <namespace>
kubectl logs -n <namespace> <pod>
```

Force reconciliation:

```bash
flux reconcile ks <name> --with-source
```

## Suspending and Resuming Flux

```bash
flux suspend ks <name> -n flux-system
flux resume ks <name> -n flux-system
flux suspend hr <name> -n <namespace>
flux resume hr <name> -n <namespace>
```

## Post-Merge Cleanup

After a bookmark is merged to `main`, clean up stale bookmarks and move the working copy back to main:

```bash
jj git fetch
jj bookmark delete <bookmark-name>
jj git push --deleted
jj new main
```

If multiple bookmarks were merged, delete them all before a single `jj git push --deleted`. Always leave the working copy on or above `main`, never on a stale merged revision.
