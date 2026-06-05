# Documentation

Reference material for this repository. The root [`README.md`](../README.md) covers the stack overview and deployment, this directory holds longer-form notes that don't belong inline.

## Available documents

- [Alloy](./alloy.md) - the DaemonSet collector that fans telemetry out to Loki, Prometheus, Mimir and Tempo.
- [Loki](./loki.md) - logs backend, single-binary mode on local filesystem.
- [Mimir](./mimir.md) - long-term metrics store, default Grafana data source.
- [Prometheus](./prometheus.md) - short-term metrics and rule evaluation, runs alongside Mimir.
- [Tempo](./tempo.md) - traces backend with span-derived metrics and cross-data-source links.
- [Pyroscope](./pyroscope.md) - profiles backend, scrapes annotated pods through an embedded Alloy config.
- [Grafana](./grafana.md) - visualisation layer, provisioned data sources, cross-source jumps and the full plugin preinstall list.
