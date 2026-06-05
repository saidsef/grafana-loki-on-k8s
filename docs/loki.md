# Loki

Loki is the logs backend. It runs in single-binary mode (`-target=all`), stores log chunks and the TSDB index on a local filesystem, and serves the LogQL API on `:3100`. Config lives in [`deployment/loki/cm.yml`](../deployment/loki/cm.yml).

It is single tenant (`auth_enabled: false`), no replication, no external ring. Anything older than 7 days is rejected at the ingester.

## What it runs

- StatefulSet, single replica, image `docker.io/grafana/loki:3.7.2`.
- Args: `-target=all -config.file=/etc/loki/loki.yaml`.
- Port: 3100 (HTTP). Service `loki` exposes the same port.
- Resources: requests 50m CPU / 512Mi, limits 100m CPU / 768Mi.
- Storage: one 2 Gi emptyDir mounted at `/data` (subPath `data`) and `/wal` (subPath `wal`).
- Security: non-root UID/GID 10001, read-only root filesystem, all caps dropped, no privilege escalation.
- Probes: HTTP `/ready` and TCP on `:3100`.

## Configuration

Single tenant, no auth:

```yaml
auth_enabled: false
server:
  http_listen_port: 3100
  log_format: json
  log_level: warn
```

Local filesystem for chunks and ring state, replication factor 1:

```yaml
common:
  path_prefix: /data
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory
  replication_factor: 1
  storage:
    filesystem:
      chunks_directory: /data/chunks
      rules_directory: /data/rules
```

TSDB schema v13, one index file per 24 hours:

```yaml
schema_config:
  configs:
    - from: "2020-05-15"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        period: 24h
        prefix: index_
```

Reject anything older than 7 days, allow structured metadata and discover log levels from incoming streams:

```yaml
limits_config:
  allow_structured_metadata: true
  discover_log_levels: true
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  volume_enabled: true
```

Compactor handles retention deletes locally:

```yaml
compactor:
  working_directory: /data/compactor
  retention_enabled: true
  delete_request_store: filesystem
```

Pattern ingester is on (`pattern_ingester.enabled: true`) and self-tracing is on (`tracing.enabled: true`), so Loki itself can export OTLP spans through Alloy.

## Inputs

[Alloy](./alloy.md) is the only writer. From [`deployment/alloy/cm.yml`](../deployment/alloy/cm.yml):

```river
loki.write "loki" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

That writer is fed by three sources in Alloy: pod logs, Kubernetes events and syslog (TCP `:51893`, UDP `:51898`).

## Outputs

Grafana reads Loki at `http://loki:3100` (see `loki.yaml` in [`deployment/grafana/cm.yml`](../deployment/grafana/cm.yml)). A `derivedFields` rule on the data source extracts `"trace_id":"..."` substrings from log lines and renders them as click-through links into the [Tempo](./tempo.md) data source:

```yaml
derivedFields:
  - datasourceUid: Tempo
    matcherRegex: '"trace_id":"(.+?)"'
    name: TraceID
    url: "$${__value.raw}"
```

## How it fits the stack

- Logs in from [Alloy](./alloy.md), queries out to Grafana.
- The trace-id link in Grafana joins logs to [Tempo](./tempo.md) spans, which is why every log line written by an instrumented app should include `trace_id`.
- Local filesystem storage means scaling out would need object storage and a real ring backend. For this repo, single replica is the deliberate choice.
