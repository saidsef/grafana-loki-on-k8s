# Tempo

Tempo is the traces backend. Single binary (`target: all`), filesystem storage, single replica, multi-protocol ingest. Config lives in [`deployment/tempo/cm.yml`](../deployment/tempo/cm.yml).

Beyond storing spans, it runs a `metrics_generator` that converts spans into RED metrics and service-graph metrics, then writes them to both Prometheus and Mimir.

## What it runs

- StatefulSet, single replica, image `docker.io/grafana/tempo:2.10.3`.
- Args: `-target=all -config.file=/conf/tempo.yaml -mem-ballast-size-mbs=512 -generator.instance-id=$(POD_IP)`.
- Ports: 3100 (HTTP query), 9095 (gRPC), 4317 (OTLP gRPC), 4318 (OTLP HTTP), 14250 (Jaeger gRPC), 14268 (Jaeger Thrift HTTP), 6831 / 6832 (Jaeger Thrift UDP), 9411 (Zipkin), 55678 (OpenCensus).
- Resources: requests 50m CPU / 512Mi, limits 100m CPU / 896Mi.
- Storage: single 10 Gi emptyDir, split across `/var/tempo/wal`, `/var/tempo/traces`, `/var/tempo/generator/wal`, `/var/tempo/generator/traces` via subPaths.
- Security: read-only root filesystem, all caps dropped, no privilege escalation.

## Configuration

Single tenant, usage reporting off:

```yaml
target: all
multitenancy_enabled: false
usage_report:
  reporting_enabled: false
```

All ingest receivers in one block:

```yaml
distributor:
  max_attribute_bytes: 512
  receivers:
    jaeger:
      protocols:
        grpc:           { endpoint: 0.0.0.0:14250 }
        thrift_binary:  { endpoint: 0.0.0.0:6832 }
        thrift_compact: { endpoint: 0.0.0.0:6831 }
        thrift_http:    { endpoint: 0.0.0.0:14268 }
    otlp:
      protocols:
        grpc: { endpoint: 0.0.0.0:4317 }
        http: { endpoint: 0.0.0.0:4318 }
```

Local filesystem, vParquet4 blocks:

```yaml
storage:
  trace:
    backend: local
    block:
      version: vParquet4
      bloom_filter_false_positive: .05
    local:
      path: /var/tempo/traces
    wal:
      search_encoding: snappy
      path: /var/tempo/wal
```

Compaction is aggressive given the small storage budget, blocks live 48 hours:

```yaml
compactor:
  compaction:
    block_retention: 48h
    compacted_block_retention: 1h
    compaction_cycle: 1h
    compaction_window: 2h
```

Metrics-generator ring rides on memberlist, processors enabled in `overrides.defaults`:

```yaml
overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics, local-blocks]
      generate_native_histograms: both
```

The generator writes those metrics to both Prometheus and Mimir:

```yaml
metrics_generator:
  storage:
    remote_write:
      - url: http://prometheus-server/api/v1/write
        send_exemplars: true
        name: prometheus
      - url: http://mimir/api/v1/push
        send_exemplars: true
        name: mimir
```

## Inputs

[Alloy](./alloy.md) pushes OTLP traces to `tempo:4317`, from [`deployment/alloy/cm.yml`](../deployment/alloy/cm.yml):

```river
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo:4317"
    tls {
      insecure             = true
      insecure_skip_verify = true
    }
  }
}
```

The other receivers (Jaeger, Zipkin, OpenCensus) are available but nothing in this repo writes to them.

## Outputs

Tempo is its own data source in Grafana at `http://tempo:3100`. It is also the linker that wires the rest of the stack together:

```yaml
- name: Tempo
  type: tempo
  url: http://tempo:3100
  jsonData:
    httpMethod: GET
    tracesToLogsV2:   { datasourceUid: Loki, spanStartTimeShift: '-15m', spanEndTimeShift: '15m', filterByTraceID: true }
    tracesToMetrics:  { datasourceUid: Mimir }
    tracesToProfiles: { datasourceUid: Pyroscope, tags: ['job', 'instance', 'pod', 'namespace'] }
    serviceMap:       { datasourceUid: Mimir }
    lokiSearch:       { datasourceUid: Loki }
    nodeGraph: { enabled: true }
```

The generated span metrics arrive in Mimir and Prometheus, where Grafana reads them through the Mimir data source for the `serviceMap` and `tracesToMetrics` panels.

## How it fits the stack

- Spans in from [Alloy](./alloy.md), metrics out to [Prometheus](./prometheus.md) and [Mimir](./mimir.md), correlated jumps to [Loki](./loki.md) and [Pyroscope](./pyroscope.md) handled by the data-source config.
- The `local-blocks` processor is what makes TraceQL metrics queries work.
- Single replica means HA is not a goal here. The 10 Gi emptyDir caps how much history fits, the 48-hour retention is sized for it.
