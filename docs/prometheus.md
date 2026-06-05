# Prometheus

Prometheus runs alongside [Mimir](./mimir.md) rather than in front of it. It scrapes Kubernetes via service discovery, accepts remote_write from Alloy, evaluates alerting and recording rules, and serves the query API to Grafana. Config lives in [`deployment/prometheus/cm.yml`](../deployment/prometheus/cm.yml).

The `remote_write` to Mimir is intentionally commented out. Alloy writes to both backends directly.

## What it runs

- Deployment, single replica, image `docker.io/prom/prometheus:v3.11.3`.
- Args: `--storage.tsdb.retention.time=15d --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus/data/ --web.enable-remote-write-receiver --web.enable-otlp-receiver --web.enable-lifecycle --enable-feature=concurrent-rule-eval,promql-experimental-functions,exemplar-storage,promql-per-step-stats,native-histograms --log.level=warn --log.format=json`.
- Port: 9090 (exposed on the Service `prometheus-server` as port 80).
- Resources: requests 100m CPU / 512Mi, limits 150m CPU / 894Mi.
- Storage: 5 Gi emptyDir at `/prometheus/data`.
- Security: non-root UID/GID 10001, read-only root filesystem, all caps dropped.
- RBAC: ServiceAccount `prometheus` with cluster-wide read on nodes, pods, services, endpoints, endpointslices, ingresses and configmaps, plus access to `/metrics` non-resource URLs.

## Configuration

Globals are conservative, 1 minute everywhere:

```yaml
global:
  evaluation_interval: 1m
  scrape_interval: 1m
  scrape_timeout: 10s
```

The Mimir remote_write hint is left in the config as a comment:

```yaml
# remote_write:
# - name: mimir
#   url: http://mimir/api/v1/push
```

Rules and alerts are read from the same ConfigMap:

```yaml
rule_files:
  - /etc/config/recording_rules.yml
  - /etc/config/alerting_rules.yml
  - /etc/config/rules
  - /etc/config/alerts
```

The alerting rules cover container memory (percent of limit, absolute size, consumption rate), NodeJS heap headroom, JVM heap, NGINX ingress (config reload failures, 4xx and 5xx rates, sudden 200 drops) and the catch-all `InstanceDown` on `up == 0`. The one recording rule, `job:request_duration_seconds:sum_rate5m`, aggregates Hubble HTTP buckets.

Scrape jobs use standard Kubernetes service-discovery patterns:

- `prometheus` itself on `localhost:9090`.
- `kubernetes-apiservers` (endpoints role, kept on the `default/kubernetes/https` endpoint).
- `kubernetes-nodes` and `kubernetes-nodes-cadvisor`, both proxied through the API server at `/api/v1/nodes/$NODE/proxy/metrics{,/cadvisor}`.
- `kubernetes-service-endpoints` and `kubernetes-pods`, gated on `prometheus.io/scrape: "true"` annotations and honoring `prometheus.io/scheme`, `path`, `port`, `param_*`.
- `*-slow` variants of the above two, gated on `prometheus.io/scrape_slow: "true"` and dialed back to 5 minute interval / 30 second timeout.
- `prometheus-pushgateway` (service role, kept on `prometheus.io/probe: pushgateway`).
- `kubernetes-services`, which proxies `/probe` through a `blackbox` exporter for services with `prometheus.io/probe: "true"`.

## Inputs

Three paths:

1. Direct scrape, driven by `prometheus.io/scrape` annotations on services and pods.
2. Remote write from [Alloy](./alloy.md). The receiver is enabled via `--web.enable-remote-write-receiver`:

   ```river
   prometheus.remote_write "prometheus" {
     endpoint {
       url                    = "http://prometheus-server/api/v1/write"
       send_exemplars         = true
       send_native_histograms = true
     }
   }
   ```

3. Span-derived metrics from [Tempo](./tempo.md)'s `metrics_generator`:

   ```yaml
   metrics_generator:
     storage:
       remote_write:
         - url: http://prometheus-server/api/v1/write
           send_exemplars: true
           name: prometheus
   ```

OTLP receive is enabled too (`--web.enable-otlp-receiver`) but nothing in this stack uses it directly.

## Outputs

Grafana queries Prometheus at `http://prometheus-server`. Same exemplar wiring as Mimir, pointing to Tempo:

```yaml
- name: Prometheus
  type: prometheus
  url: http://prometheus-server
  jsonData:
    prometheusType: Prometheus
    exemplarTraceIdDestinations:
      - name: trace_id
        datasourceUid: Tempo
```

## How it fits the stack

- Short-lived working copy of metrics, retained 15 days locally. [Mimir](./mimir.md) keeps the same data under the same retention.
- The lifecycle endpoint is on (`--web.enable-lifecycle`), so `curl -X POST :9090/-/reload` reloads config without a restart.
- Because Alloy writes the same series to both Prometheus and Mimir, dashboards built on either data source will look the same.
