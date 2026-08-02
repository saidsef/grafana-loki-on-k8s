# Alloy

Alloy is the collector that feeds everything else in this stack. It runs as a DaemonSet so there is one on every node, scrapes Prometheus targets and pod logs from the local kubelet, accepts OTLP traffic from applications, and scrapes pprof endpoints off annotated pods for Pyroscope. Logs go to Loki, metrics fan out to both Prometheus and Mimir, traces go to Tempo, profiles go to Pyroscope. Config lives in [`deployment/alloy/cm.yml`](../deployment/alloy/cm.yml).

This stack uses Alloy in place of Promtail. The Promtail directory is still in the tree but is commented out in [`deployment/kustomization.yml`](../deployment/kustomization.yml).

## What it runs

- DaemonSet, image `docker.io/grafana/alloy:v1.18.0`.
- Args: `run /etc/alloy/config.alloy --storage.path=/tmp/alloy --server.http.listen-addr=$(POD_IP):12345 --server.http.ui-path-prefix=/ --stability.level=public-preview --feature.community-components.enabled --cluster.enabled=true --cluster.name=$(CLUSTER_NAME) --cluster.wait-for-size=1`.
- `CLUSTER_NAME` is read from the pod label `cluster` via the downward API, so it's set in the DaemonSet pod template rather than hardcoded in the args.
- Ports: 12345 (HTTP UI and self metrics), 4317 (OTLP gRPC), 4318 (OTLP HTTP).
- Resources: requests 50m CPU / 512Mi, limits 100m CPU / 896Mi.
- Storage: 1 Gi emptyDir at `/tmp/alloy` for remote_write WAL buffers.
- Security: unprivileged — `privileged: false`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, `runAsUser: 473`, all capabilities dropped, `seccompProfile: RuntimeDefault`.
- RBAC: ClusterRole grants list/watch on pods, services, nodes, endpoints, endpointslices, ingresses, events, configmaps and replicasets, plus the Prometheus operator CRDs (`podmonitors`, `servicemonitors`, `probes`, `scrapeconfigs`, `prometheusrules`) and `monitoring.grafana.com/podlogs`.

## Configuration

Logs go to Loki via one writer:

```river
loki.write "loki" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

Two log sources feed that writer: pod logs (`loki.source.kubernetes "pods"`, filtered to drop anything older than 1 hour) and cluster events (`loki.source.kubernetes_events "cluster"`).

Metrics fan out to both Prometheus and Mimir, with exemplars and native histograms on each:

```river
prometheus.remote_write "prometheus" {
  endpoint {
    url                    = "http://prometheus-server/api/v1/write"
    remote_timeout         = "10s"
    send_exemplars         = true
    send_native_histograms = true
  }
}

prometheus.remote_write "mimir" {
  endpoint {
    url                    = "http://mimir/api/v1/push"
    remote_timeout         = "10s"
    send_exemplars         = true
    send_native_histograms = true
  }
}
```

A single `prometheus.scrape "default"` block walks kubelet pod targets, nodes and services and forwards to both writers. Targets with `prometheus.io/scrape: "false"` get dropped during relabel.

Traces come in on OTLP, get K8s metadata attached, and are forwarded to Tempo unsampled:

```river
otelcol.receiver.otlp "otel" {
  grpc { endpoint = sys.env("POD_IP") + ":4317" }
  http { endpoint = sys.env("POD_IP") + ":4318" }

  output {
    traces = [otelcol.processor.k8sattributes.default.input]
  }
}

otelcol.processor.k8sattributes "default" {
  output {
    traces = [otelcol.processor.batch.otel.input]
  }
}

otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo:4317"
    tls { insecure = true }
  }
}
```

Batch settings: 6 second timeout, 200 spans per batch, 300 max.

### Why there is no tail sampling and no service-graph connector here

Alloy generates **no** trace-derived metrics. `traces_service_graph_*` and `traces_spanmetrics_*` come from [Tempo's](./tempo.md) `metrics_generator`, which is the only producer in this stack.

Alloy also does no sampling, deliberately. `otelcol.processor.tail_sampling` and `otelcol.connector.servicegraph` are both **stateful**: they need every span of a trace on one instance. Alloy runs as a DaemonSet behind a ClusterIP Service, so spans of a single trace land on different pods. Without an `otelcol.exporter.loadbalancing` tier routing on `traceID`, both components would work from partial traces — splitting the client/server span pairs that Tempo's service-graph processor has to match, and so producing an empty or truncated service graph.

Tail sampling also delays every span by `decision_wait` (30s by default) before releasing it. Tempo drops any span whose end time falls outside `metrics_ingestion_time_range_slack` (60s in [`deployment/tempo/cm.yml`](../deployment/tempo/cm.yml)), so that delay consumes most of the budget and silently discards spans from metric generation.

To sample at scale, add a second Alloy tier: DaemonSet agents exporting via `otelcol.exporter.loadbalancing` with `routing_key = "traceID"` into a separate Alloy Deployment behind a headless Service that runs `tail_sampling`.

## Profiling

Profiling data reaches Pyroscope through two complementary paths.

### eBPF CPU profiling via Beyla (all services, no annotations)

When Pyroscope is included in the kustomization, a patch is applied to Beyla's ConfigMap that activates `otel_profiles_export`. Beyla uses eBPF perf events to collect CPU flame graphs from every process it discovers — any language, zero application changes. Profiles are pushed directly to Pyroscope at `http://pyroscope:4040` with a 30-second retry window before dropping. When Pyroscope is not deployed (commented out of `deployment/kustomization.yml`), the patch is never applied and Beyla has no profiling overhead.

### pprof scraping via Alloy (Go services, opt-in)

Alloy actively pulls pprof endpoints from annotated pods and forwards to Pyroscope. Memory, CPU, and goroutine profiles are opt-in; block, mutex, and fgprof remain explicitly opt-in due to runtime overhead.

**Single-annotation shortcut** — add one annotation to enable memory, cpu, and goroutine profiling at once:

```yaml
metadata:
  annotations:
    profiles.grafana.com/port: "8080"
```

**Per-type annotations** — for fine-grained control or to enable block/mutex/fgprof:

```yaml
metadata:
  annotations:
    profiles.grafana.com/cpu.scrape:    "true"
    profiles.grafana.com/cpu.port:      "8080"   # port number
    # profiles.grafana.com/cpu.port_name: "http"  # or port name
    # profiles.grafana.com/cpu.scheme:    "https" # optional, default http
    # profiles.grafana.com/cpu.path:      "/debug/pprof/profile" # optional
```

**Opt-out** — suppress a specific type for a pod that would otherwise be scraped:

```yaml
metadata:
  annotations:
    profiles.grafana.com/memory.scrape: "false"
```

Supported profile types and their annotation prefix:

| Type | Annotation prefix | pprof path | Default enrolment |
|------|------------------|-----------|-------------------|
| `memory` | `profiles.grafana.com/memory` | `/debug/pprof/heap` | via `port` shortcut |
| `cpu` | `profiles.grafana.com/cpu` | `/debug/pprof/profile` | via `port` shortcut |
| `goroutine` | `profiles.grafana.com/goroutine` | `/debug/pprof/goroutine` | via `port` shortcut |
| `block` | `profiles.grafana.com/block` | `/debug/pprof/block` | explicit opt-in only |
| `mutex` | `profiles.grafana.com/mutex` | `/debug/pprof/mutex` | explicit opt-in only |
| `fgprof` | `profiles.grafana.com/fgprof` | `/debug/fgprof` | explicit opt-in only |

Scraping is distributed across Alloy instances via clustering. The `service_name` label is set from the pod's `app.kubernetes.io/name` label, falling back to the container name.

Profiles are written to Pyroscope:

```river
pyroscope.write "pyroscope" {
  endpoint {
    url                 = "http://pyroscope:4040"
    remote_timeout      = "10s"
    min_backoff_period  = "500ms"
    max_backoff_period  = "5m"
    max_backoff_retries = 3
  }
}
```

`max_backoff_retries = 3` means profiles are dropped after three failed attempts. This keeps Alloy's WAL clear when Pyroscope is not deployed alongside this stack.

## Inputs

- Applications send OTLP logs, metrics and traces to the `alloy` Service on port 4317 (gRPC) or 4318 (HTTP). Note this is a ClusterIP Service with `internalTrafficPolicy: Cluster`, so traffic is balanced across every Alloy pod — it is not pinned to the local node.
- The kubelet at `https://$NODE_IP:10250` is the source for pod targets and pod logs.
- Pods with `profiles.grafana.com/port: "<n>"` or per-type `profiles.grafana.com/<type>.scrape: "true"` annotations are scraped for pprof profiles.

## Outputs

| To | Protocol | URL |
|---|---|---|
| [Loki](./loki.md) | Loki push API | `http://loki:3100/loki/api/v1/push` |
| [Prometheus](./prometheus.md) | Prometheus remote_write | `http://prometheus-server/api/v1/write` |
| [Mimir](./mimir.md) | Prometheus remote_write | `http://mimir/api/v1/push` |
| [Tempo](./tempo.md) | OTLP gRPC | `tempo:4317` |
| [Pyroscope](./pyroscope.md) | Pyroscope push API | `http://pyroscope:4040` |

## How it fits the stack

- Alloy is the single ingress for application telemetry. Apps point at Alloy, not at the backends directly.
- It writes metrics to Prometheus and Mimir at the same time, which is why both data sources show the same data in Grafana.
- It feeds [Pyroscope](./pyroscope.md) directly — Pyroscope has no embedded scraper of its own.
