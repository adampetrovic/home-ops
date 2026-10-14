# InfluxDB tasks

InfluxDB buckets and tasks aren't Kubernetes resources, so Flux doesn't reconcile this directory. It's the versioned source; apply changes with the `influx` CLI.

## Home Assistant downsampling

| Bucket | Contents | Retention |
|---|---|---|
| `homeassistant` | Raw points written by Home Assistant's InfluxDB integration | 90 days |
| `homeassistant_hourly` | Hourly aggregates of numeric sensors | infinite |
| `homeassistant_location` | Adam's and Odette's `person.*` points, unchanged | infinite |

`homeassistant-hourly.flux` runs at 5 past every hour and reprocesses the previous two full hours:

- **Counters** (`kWh`, `Wh`, `mm`, `coffees`, `flushes`) → `last`. Consumption over a period is the difference between `last` values.
- **Everything else numeric** → `mean`, `min`, `max`. For 0/1 flags in `units`, `mean` is the fraction of the hour the flag was on.
- **Dropped:** voltage (`V`, `mV`), `VA`, `var`, power factor, and the duplicate `*_total_energy`/`*_daily_energy` plug counters.
- **Location:** `person.adam_petrovic` and `person.odette_petrovic` are copied with every field and their original timestamps.

Points keep their measurement (unit) and tags (`domain`, `entity_id`, `friendly_name`, `source`) and are stamped at the start of the hour. Rewriting a point with the same series and time overwrites it, so overlapping runs and re-runs are safe.

## Setup

Use a token with read access to `homeassistant` and write access to the two new buckets.

```bash
export INFLUX_HOST=https://influx.petrovic.network INFLUX_ORG=<org> INFLUX_TOKEN=<token>

influx bucket create --name homeassistant_hourly --retention 0
influx bucket create --name homeassistant_location --retention 0
```

Preview the last two hours without writing anything: drop the `to()` lines and the `option task` line.

```bash
sed -e '/^option task/d' -e '/to(bucket:/d' homeassistant-hourly.flux \
    | influx query --file /dev/stdin | head -50
```

Backfill history, then create the task:

```bash
./backfill.sh 2024-03-04T00:00:00Z "$(date -u +%Y-%m-%dT%H:00:00Z)"
influx task create --file homeassistant-hourly.flux
```

## Cutover

Verify before shortening retention; dropped shards can't be recovered.

1. For a few entities, `homeassistant_hourly` has one point per hour back to their first raw point.
2. For each person, point counts and first/last timestamps match between `homeassistant` and `homeassistant_location`.
3. Daily kWh from hourly `last` matches raw `last - first` for a few sample days.
4. `influx task run list --task-id <id>` shows a day of successful runs.
5. Take a Kopiur snapshot of the `influxdb` PVC.

Then:

```bash
influx bucket update --id "$(influx bucket list --name homeassistant --hide-headers | cut -f1)" --retention 90d
```
