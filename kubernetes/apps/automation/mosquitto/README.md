# Mosquitto retained MQTT state

Mosquitto is configured with persistence enabled so retained MQTT messages survive broker pod and node restarts. This prevents Home Assistant from missing retained discovery, state, and availability messages when large upgrades restart `mosquitto`, Home Assistant, Zigbee2MQTT, Sigenergy2MQTT, or LAN MQTT clients such as Shelly1 devices in an unlucky order.

This persists topics that clients already publish with the MQTT retain flag; it does not make every MQTT message retained.

## Why not only use dependencies?

Flux dependencies help with GitOps reconciliation order, but they do not cover all failure modes:

- Talos upgrades and node drains can evict pods outside Flux dependency ordering.
- Home Assistant can restart by itself after publishers have already emitted non-retained availability messages.
- LAN MQTT clients such as Shelly devices are outside Kubernetes and cannot be ordered with Flux.
- Broker restarts clear in-memory retained messages unless Mosquitto persistence is enabled.

Keep dependencies for coarse startup ordering, but use retained state for correctness.

## What should be retained

Use retained messages deliberately:

- Home Assistant MQTT discovery topics (`homeassistant/#`).
- Normal state topics where last-known-state is useful.
- Availability topics only when the client also publishes a matching retained `offline` message via Last Will or a clean shutdown path.

Do **not** retain command, action, or one-shot event topics such as `.../set`, `.../command`, button events, or transient actions.

## Downsides to watch for

- A stale retained `online` message can make Home Assistant show a device as available after the device has died if there is no matching retained `offline`/LWT behaviour.
- Retained discovery topics can create ghost entities after device renames or removals until the retained discovery config is cleared.
- Retained state can make old sensor values appear immediately after a Home Assistant restart; use availability or `expire_after` where stale data is unsafe.
- Retained MQTT payloads are written to the `mosquitto-cephfs` CephFS PVC. This PVC is intentionally not backed up by VolSync.

Clear a bad retained topic by publishing a zero-length retained payload. Mosquitto requires authentication; load `MQTT_USERNAME` and `MQTT_PASSWORD` from the `mosquitto-secret` Kubernetes Secret or 1Password first.

```bash
mosquitto_pub -h mqtt.${SECRET_DOMAIN} -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" -r -n -t '<topic>'
```

## Validation after upgrades

Check retained topics before and after restarting Mosquitto and Home Assistant:

```bash
mosquitto_sub -h mqtt.${SECRET_DOMAIN} -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" --retained-only -t 'homeassistant/#' -v
mosquitto_sub -h mqtt.${SECRET_DOMAIN} -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" --retained-only -t 'zigbee2mqtt/#' -v
mosquitto_sub -h mqtt.${SECRET_DOMAIN} -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" --retained-only -t 'sigenergy2mqtt/#' -v
mosquitto_sub -h mqtt.${SECRET_DOMAIN} -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" --retained-only -t 'shellies/#' -v
mosquitto_sub -h mqtt.${SECRET_DOMAIN} -u "$MQTT_USERNAME" -P "$MQTT_PASSWORD" --retained-only -t 'shelly/#' -v
```

Shelly Gen1 devices commonly use `shellies/<device-id>/...`; newer devices or custom configurations may use a different prefix.
