// Downsamples Home Assistant's raw `homeassistant` bucket into hourly
// aggregates, and copies Adam's and Odette's location history unchanged.
// Applied by hand with the influx CLI; see README.md. backfill.sh reuses this
// file by replacing the `start`/`stop` lines.
option task = {name: "homeassistant-hourly", every: 1h, offset: 5m}

import "date"

stop = date.truncate(t: now(), unit: 1h)
start = date.sub(d: 2h, from: stop)

// Cumulative counters keep the last value in each hour; everything else keeps
// mean, min and max. Measurement names are units (default_measurement: units).
counterUnits = ["kWh", "Wh", "mm", "coffees", "flushes"]
droppedUnits = ["V", "mV", "VA", "var"]
people = ["adam_petrovic", "odette_petrovic"]

raw = from(bucket: "homeassistant")
    |> range(start: start, stop: stop)

raw
    |> filter(fn: (r) => r.domain == "person" and contains(value: r.entity_id, set: people))
    |> to(bucket: "homeassistant_location")
    |> yield(name: "location")

values = raw
    |> filter(fn: (r) => r._field == "value" and r.domain != "person")
    |> filter(fn: (r) => not contains(value: r._measurement, set: droppedUnits))
    |> filter(fn: (r) => r.entity_id !~ /_(total_energy|reactive_power|apparent_power|power_factor)$/)
    |> filter(fn: (r) => r.entity_id !~ /^(server_rack|dishwasher|dryer|washing_machine|coffee)_daily_energy$/)

counters = values
    |> filter(fn: (r) => contains(value: r._measurement, set: counterUnits))

gauges = values
    |> filter(fn: (r) => not contains(value: r._measurement, set: counterUnits))

hourly = (tables=<-, fn, field) => tables
    |> aggregateWindow(every: 1h, fn: fn, createEmpty: false, timeSrc: "_start")
    |> set(key: "_field", value: field)

union(
    tables: [
        counters |> hourly(fn: last, field: "last"),
        gauges |> hourly(fn: mean, field: "mean"),
        gauges |> hourly(fn: min, field: "min"),
        gauges |> hourly(fn: max, field: "max"),
    ],
)
    |> to(bucket: "homeassistant_hourly")
    |> yield(name: "hourly")
