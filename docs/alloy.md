# Alloy

Alloy is the collector that feeds everything else in this stack. It runs as a DaemonSet so there is one on every node, scrapes Prometheus targets and pod logs from the local kubelet, and accepts OTLP traffic from applications. Logs go to Loki, metrics fan out to both Prometheus and Mimir, traces go to Tempo. Config lives in [`deployment/alloy/cm.yml`](../deployment/alloy/cm.yml).

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

## Inputs

- Applications send OTLP logs, metrics and traces to the local Alloy on the node, port 4317 (gRPC) or 4318 (HTTP).
- The kubelet at `https://$NODE_IP:10250` is the source for pod targets and pod logs.

## Outputs

| To | Protocol | URL |
|---|---|---|
| [Loki](./loki.md) | Loki push API | `http://loki:3100/loki/api/v1/push` |
| [Prometheus](./prometheus.md) | Prometheus remote_write | `http://prometheus-server/api/v1/write` |
| [Mimir](./mimir.md) | Prometheus remote_write | `http://mimir/api/v1/push` |
| [Tempo](./tempo.md) | OTLP gRPC | `tempo:4317` |

## How it fits the stack

- Alloy is the single ingress for application telemetry. Apps point at Alloy, not at the backends directly.
- It writes metrics to Prometheus and Mimir at the same time, which is why both data sources show the same data in Grafana.
- It does not feed [Pyroscope](./pyroscope.md). Profile scraping is handled by an Alloy River config that lives inside the Pyroscope ConfigMap and runs in the Pyroscope pod itself.
