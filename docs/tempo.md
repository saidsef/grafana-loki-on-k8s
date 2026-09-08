# Tempo

Tempo is the traces backend. Single binary (`target: all`), filesystem storage, single replica, multi-protocol ingest. Config lives in [`deployment/tempo/cm.yml`](https://github.com/saidsef/grafana-loki-on-k8s/blob/main/deployment/tempo/cm.yml).

Beyond storing spans, it runs a `metrics_generator` that converts spans into RED metrics and service-graph metrics, then writes them to Mimir.

## What it runs

- StatefulSet, single replica, image `docker.io/grafana/tempo:3.0.3`.
- Args: `-config.file=/conf/tempo.yaml -config.expand-env=true -generator.instance-id=$(POD_IP) -log.level=warn`.
- Ports: 3100 (HTTP query), 9095 (gRPC), 4317 (OTLP gRPC), 4318 (OTLP HTTP), 14250 (Jaeger gRPC), 14268 (Jaeger Thrift HTTP), 6831 / 6832 (Jaeger Thrift UDP), 9411 (Zipkin).
- Resources: requests 50m CPU / 512Mi, limits 100m CPU / 896Mi.
- Storage: single 10 Gi emptyDir mounted at `/var/tempo`, holding the WAL, blocks, generator WAL and live-store data.
- Security: read-only root filesystem, all caps dropped, no privilege escalation.
- A headless service (`tempo-headless`) exists alongside the ClusterIP service to satisfy the StatefulSet governing service requirement.

## Configuration

Single tenant, usage reporting off:

```yaml
target: all
multitenancy_enabled: false
usage_report:
  reporting_enabled: false
```

All ingest receivers in one block. `max_attribute_bytes` is set to the Tempo default — anything lower silently truncates attribute values:

```yaml
distributor:
  max_attribute_bytes: 2048
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

Local filesystem, vParquet5 blocks. Tempo 3.0 still defaults to vParquet4, so this is opt-in.
vParquet5 adds dedicated columns for integer and event attributes and the `span:childCount`
intrinsic. Older blocks stay readable, and new blocks are written in the new format:

```yaml
storage:
  trace:
    backend: local
    block:
      version: vParquet5
      bloom_filter_false_positive: .05
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
```

Compaction is aggressive given the small storage budget, blocks live 48 hours. Tempo 3.0
replaced the compactor with a backend scheduler that hands jobs to a backend worker, so the
same retention is set on both. Without it the 3.0 default of 336h applies:

```yaml
backend_scheduler:
  provider:
    compaction:
      compaction:
        block_retention: 48h
        compacted_block_retention: 1h
        compaction_cycle: 1h
        compaction_window: 2h
backend_worker:
  compaction:
    block_retention: 48h
    compacted_block_retention: 1h
    compaction_cycle: 1h
    compaction_window: 2h
```

Metrics-generator ring rides on memberlist, three processors enabled:

```yaml
overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics, host-info]
      generate_native_histograms: classic
```

`host-info` emits a `traces_host_info` gauge keyed on `k8s.node.name` and `host.id`. `service-graphs` is tuned with a 60s wait to allow time for cross-node span pairs, plus peer_attributes and dimensions for richer label coverage.

`enable_virtual_node_label` is deliberately left off. On 3.0.3 it stops virtual-node edges being emitted at all, and every edge here is a virtual node - client spans naming an uninstrumented peer through `peer.service`, which is what produces the `client=<service>` to `server=elasticsearch` edges. Turning it on empties the service graph while span metrics carry on unaffected, so the generator looks healthy.

The generator writes metrics to Mimir:

```yaml
metrics_generator:
  storage:
    remote_write:
      # - url: http://prometheus-server/api/v1/write
      #   send_exemplars: true
      #   name: prometheus
      - url: http://mimir/api/v1/push
        send_exemplars: true
        name: mimir
```

The querier connects to the co-located frontend using the pod IP, injected at startup via `-config.expand-env=true`:

```yaml
querier:
  max_concurrent_queries: 20
  frontend_worker:
    frontend_address: ${POD_IP}:9095
```

## Inputs

[Alloy](./alloy.md) pushes OTLP traces to `tempo:4317`, from [`deployment/alloy/cm.yml`](https://github.com/saidsef/grafana-loki-on-k8s/blob/main/deployment/alloy/cm.yml):

```river
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo:4317"
    tls {
      insecure = true
    }
  }
}
```

The Jaeger and Zipkin receivers are available for services that instrument with those SDKs directly.

For NodeJS services, [`@saidsef/tracing-node`](https://github.com/saidsef/tracing-node) wraps the OpenTelemetry SDK and registers the W3C Trace Context propagator. That propagation is what the `service-graphs` processor needs: without a client span carrying `traceparent` to the callee, each service starts its own trace and the graph can only ever show virtual nodes.

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
- TraceQL metrics queries are served from the live-store and backend blocks. Tempo 3.0 removed the `local-blocks` processor that previously backed them, and only reads RF1 blocks written by 3.0, so coverage starts at the upgrade. Storage is an emptyDir here, so nothing predates it anyway.
- Single replica means HA is not a goal here. The 10 Gi emptyDir caps how much history fits, the 48-hour retention is sized for it.
