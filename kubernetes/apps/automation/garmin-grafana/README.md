# Garmin Grafana Collector

Fetches Garmin Connect health and activity data into the existing InfluxDB deployment for visualization in Grafana.

## Data path

- Collector namespace: `automation`
- InfluxDB endpoint: `influxdb.observability.svc.cluster.local:8086`
- InfluxDB bucket: `garmin`
- InfluxQL DBRP: `GarminStats/autogen`
- Garmin OAuth token storage: `/home/appuser/.garminconnect` on the `garmin-grafana` PVC

The collector uses InfluxDB 2's authenticated v1 compatibility API. Its v1-compatible credential requires read and write access because the collector queries the latest `HeartRateIntraday` point before fetching updates.

## Garmin authentication bootstrap

Garmin OAuth tokens must be generated interactively before the collector is enabled. Keep `controllers.garmin-grafana.replicas` at `0` until the PVC exists and token bootstrap is complete.

Use a temporary interactive pod with the same image, UID/GID, InfluxDB secret, and `garmin-grafana` PVC. Generate the Garmin session in `/home/appuser/.garminconnect`, then delete the pod immediately. Do not store the Garmin password in Git, Kubernetes, or 1Password solely for steady-state operation.

Repeated unauthenticated restarts can trigger multiple MFA prompts and Garmin rate limiting. Scale the collector back to zero before renewing an expired session.

## Backfill

The normal collector defaults to a seven-day initial fetch. For older history, run a separate one-off pod with `MANUAL_START_DATE` and optional `MANUAL_END_DATE`. Do not set batch-mode dates on the permanent Deployment because the process exits when the backfill finishes.

## Operations

```bash
# Collector and secret state
kubectl get hr,externalsecret,pod -n automation -l app.kubernetes.io/name=garmin-grafana

# Recent logs
kubectl logs -n automation deploy/garmin-grafana --tail=200

# Snapshot Garmin OAuth tokens
task volsync:snapshot app=garmin-grafana ns=automation
```

The OAuth token files are sensitive and are included in encrypted Kopia and R2 VolSync backups.
