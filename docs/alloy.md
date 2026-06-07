# Alloy

Alloy is the collector that feeds everything else in this stack. It runs as a DaemonSet so there is one on every node, scrapes Prometheus targets and pod logs from the local kubelet, accepts OTLP traffic from applications, and scrapes pprof endpoints off annotated pods for Pyroscope. Logs go to Loki, metrics fan out to both Prometheus and Mimir, traces go to Tempo, profiles go to Pyroscope. Config lives in [`deployment/alloy/cm.yml`](../deployment/alloy/cm.yml).

This stack uses Alloy in place of Promtail. The Promtail directory is still in the tree but is commented out in [`deployment/kustomization.yml`](../deployment/kustomization.yml).

## What it runs

- DaemonSet, image `docker.io/grafana/alloy:v1.16.2`.
- Args: `run /etc/alloy/config.alloy --storage.path=/tmp/alloy --server.http.listen-addr=$(POD_IP):12345 --stability.level=public-preview --feature.community-components.enabled --cluster.enabled=true --cluster.name=$(CLUSTER_NAME) --cluster.wait-for-size=1`.
- `CLUSTER_NAME` is read from the pod label `cluster` via the downward API, so it's set in the DaemonSet pod template rather than hardcoded in the args.
- Ports: 12345 (HTTP UI and self metrics), 4317 (OTLP gRPC), 4318 (OTLP HTTP).
- Resources: requests 50m CPU / 512Mi, limits 100m CPU / 896Mi.
- Storage: 1 Gi emptyDir at `/tmp/alloy` for remote_write WAL buffers.
- Security: privileged container so it can read kubelet metrics and pod stdout, read-only root filesystem, runs as UID 0.
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

Traces come in on OTLP, get K8s metadata attached, pass through tail sampling, and split: one copy goes to Tempo, the other feeds the service-graph connector:

```river
otelcol.receiver.otlp "otel" {
  grpc { endpoint = sys.env("POD_IP") + ":4317" }
  http { endpoint = sys.env("POD_IP") + ":4318" }
}

otelcol.processor.tail_sampling "rate_limiter" {
  policy {
    name = "sample-errors"
    type = "status_code"
    status_code { status_codes = ["ERROR"] }
  }
  policy {
    name = "rate-limit-ok"
    type = "rate_limiting"
    rate_limiting { spans_per_second = 400 }
  }
}

otelcol.connector.servicegraph "tempo" {
  dimensions = ["http.method", "http.request.method", "http.target", "url.path"]
  output {
    metrics = [otelcol.exporter.prometheus.otel.input]
  }
}

otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo:4317"
    tls { insecure = true }
  }
}
```

Errored spans are always sampled, everything else is capped at 400 spans/s. The service-graph connector emits `traces_service_graph_*` metrics for span pairs it sees on the local node.

Batch settings: 6 second timeout, 200 spans per batch, 300 max.

## Profiling

Alloy scrapes pprof endpoints off annotated pods and forwards them to Pyroscope. Pods opt in per profile type:

```yaml
metadata:
  annotations:
    profiles.grafana.com/cpu.scrape:    "true"
    profiles.grafana.com/cpu.port:      "8080"   # port number
    # profiles.grafana.com/cpu.port_name: "http"  # or port name
    # profiles.grafana.com/cpu.scheme:    "https" # optional, default http
    # profiles.grafana.com/cpu.path:      "/debug/pprof/profile" # optional
```

Supported profile types and their annotation prefix:

| Type | Annotation prefix | pprof path |
|------|------------------|-----------|
| `memory` | `profiles.grafana.com/memory` | `/debug/pprof/heap` |
| `cpu` | `profiles.grafana.com/cpu` | `/debug/pprof/profile` |
| `goroutine` | `profiles.grafana.com/goroutine` | `/debug/pprof/goroutine` |
| `block` | `profiles.grafana.com/block` | `/debug/pprof/block` |
| `mutex` | `profiles.grafana.com/mutex` | `/debug/pprof/mutex` |
| `fgprof` | `profiles.grafana.com/fgprof` | `/debug/fgprof` |

Each type is independently opt-in. Scraping is distributed across Alloy instances via clustering. The `service_name` label is set from the pod's `app.kubernetes.io/name` label, falling back to the container name.

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

- Applications send OTLP logs, metrics and traces to the local Alloy on the node, port 4317 (gRPC) or 4318 (HTTP).
- The kubelet at `https://$NODE_IP:10250` is the source for pod targets and pod logs.
- Pods with `profiles.grafana.com/<type>.scrape: "true"` annotations are scraped for profiles.

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
