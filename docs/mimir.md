# Mimir

Mimir is the long-term metrics store. It runs in single-binary mode (`target: all,overrides-exporter`) on filesystem storage, single tenant, single replica. The Prometheus-compatible API lives behind `/prometheus` on the service. Config lives in [`deployment/mimir/cm.yml`](../deployment/mimir/cm.yml).

## What it runs

- StatefulSet, single replica, image `docker.io/grafana/mimir:3.0.6`.
- Args (besides `-config.file=/conf/mimir.yaml`): `-auth.multitenancy-enabled=false -auth.no-auth-tenant=anonymous -compactor.blocks-retention-period=15d -distributor.ha-tracker.enable-for-all-users=true -querier.cardinality-analysis-enabled=true -blocks-storage.storage-prefix=blocks -ingester.out-of-order-time-window=15m -log.format=json -log.level=warn`.
- Ports: 8080 (HTTP, exposed on the Service as port 80), 9095 (gRPC).
- Resources: requests 100m CPU / 512Mi, limits 100m CPU / 768Mi.
- Storage: separate emptyDirs for `/data` (2 Gi), `/tsdb` (5 Gi), `/tsdb-sync` (1 Gi), `/rules` (1 Gi), `/ruler` (1 Gi), `/compactor` (1 Gi).
- Security: non-root, read-only root filesystem, all caps dropped.
- ServiceAccount: `mimir`.

## Configuration

Single tenant, everything under `anonymous`:

```yaml
multitenancy_enabled: false
no_auth_tenant: anonymous
```

Filesystem backend for blocks, rules and ruler state:

```yaml
common:
  storage:
    backend: filesystem
    filesystem:
      dir: /data

blocks_storage:
  bucket_store:
    sync_dir: /tsdb-sync/
    ignore_blocks_within: 0s
  storage_prefix: blocks
  tsdb:
    dir: /tsdb/
    wal_compression_enabled: true
```

Replication factor 1 on both the ingester and the store-gateway rings:

```yaml
ingester:
  ring:
    replication_factor: 1
  push_circuit_breaker:
    request_timeout: 10s

store_gateway:
  sharding_ring:
    replication_factor: 1
```

Block retention of 15 days is set on the command line (`-compactor.blocks-retention-period=15d`), not in the YAML. The compactor cleans up every hour with a 1-hour grace window:

```yaml
compactor:
  cleanup_interval: 1h
  data_dir: /compactor/
  deletion_delay: 1h
```

Ruler reads rules from local disk:

```yaml
ruler_storage:
  backend: local
  local:
    directory: /rules
ruler:
  rule_path: /ruler
```

Distributors give up after 5 seconds, all experimental PromQL functions are unlocked.

## Inputs

Two writers, both pushing to the same URL.

[Alloy](./alloy.md), from [`deployment/alloy/cm.yml`](../deployment/alloy/cm.yml):

```river
prometheus.remote_write "mimir" {
  endpoint {
    url                    = "http://mimir/api/v1/push"
    send_exemplars         = true
    send_native_histograms = true
  }
}
```

[Tempo](./tempo.md)'s `metrics_generator`, from [`deployment/tempo/cm.yml`](../deployment/tempo/cm.yml):

```yaml
metrics_generator:
  storage:
    remote_write:
      - url: http://mimir/api/v1/push
        send_exemplars: true
        name: mimir
```

The Tempo writes carry RED metrics and service-graph metrics derived from spans.

## Outputs

Mimir is the default Grafana data source (`isDefault: true`), pointed at `http://mimir/prometheus`:

```yaml
- name: Mimir
  type: prometheus
  isDefault: true
  url: http://mimir/prometheus
  jsonData:
    prometheusType: Mimir
    exemplarTraceIdDestinations:
      - name: trace_id
        datasourceUid: Tempo
```

The Tempo data source also queries Mimir for its `tracesToMetrics` and `serviceMap` lookups.

## How it fits the stack

- Long-term metrics home. Holds the same data [Prometheus](./prometheus.md) does, since [Alloy](./alloy.md) writes to both, so dashboards can pick either source.
- Tempo's span-derived metrics land here, which is what powers the service graph view in Grafana.
- Exemplars carry trace IDs, so a click on a Mimir data point can jump straight into Tempo.
