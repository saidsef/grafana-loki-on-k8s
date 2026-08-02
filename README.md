# Grafana, Prometheus, Loki, Alloy, Beyla, Tempo, Pyroscope and Mimir (LGTM+)

[Loki](https://grafana.com/oss/loki/) is a horizontally-scalable, highly-available, multi-tenant log aggregation system inspired by Prometheus. It is designed to be very cost effective and easy to operate, as it does not index the contents of the logs, but rather a set of labels for each log stream.

[Alloy](https://grafana.com/docs/alloy/latest/introduction/) is a flexible, high performance, vendor-neutral distribution of the OpenTelemetry Collector. It’s fully compatible with the most popular open source observability standards such as OpenTelemetry and Prometheus.

[Beyla](https://grafana.com/docs/beyla/latest/) Grafana Beyla uses eBPF to automatically inspect application executables and the OS networking layer, and capture trace spans related to web transactions and Rate Errors Duration (RED) metrics for Linux HTTP/S and gRPC services. *All data capture occurs without any modifications to application code or configuration*.
> [!WARNING]
> [Beyla](https://grafana.com/docs/beyla/latest/security/) needs access to various Linux interfaces to instrument applications, loading eBPF programs, and managing network interface filters, these operations require elevated permissions.

[Promtail](https://grafana.com/docs/loki/latest/clients/promtail/) is an agent which ships the contents of local logs to a private Grafana Loki instance or Grafana Cloud.
> [!NOTE]
> [Alloy](https://grafana.com/docs/loki/latest/setup/migrate/migrate-to-alloy/) is a replacement for Promtil, it essentially replaces the log collector/scraper that traditionally used Promtail, Grafana Agent or OTel Agent. 

[Tempo](https://grafana.com/oss/tempo/) is an open source, easy-to-use, and high-scale distributed tracing backend. Tempo is cost-efficient, requiring only object storage to operate, and is deeply integrated with Grafana, Prometheus, and Loki. Tempo can ingest common open source tracing protocols, including Jaeger, Zipkin, and OpenTelemetry.

[Mimir](https://grafana.com/oss/mimir/) lets you scale metrics to 1 billion active series and beyond, with high availability, multi-tenancy, durable storage, and blazing fast query performance over long periods of time.

[Pyroscope](https://grafana.com/docs/pyroscope/latest/) is a multi-tenant, continuous profiling aggregation system, aligning its architectural design with Grafana Mimir, Grafana Loki, and Grafana Tempo. This integration enables a cohesive correlation of profiling data with existing metrics, logs, and traces.


I am assuming you are already familiar with [Grafana Stack](https://grafana.com/about/grafana-stack/).

## Prerequisites
- Kubernetes Cluster >= v1.28
- Familiarity with Grafana Stack
- Observability
- ...
- Profit?

## Architecture Diagram

```ascii
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GRAFANA DASHBOARD                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         UNIFIED VISUALIZATION                           ││
│  │  📊 Metrics  📝 Logs  🔗 Traces  🔥 Profiles  🚨 Alerts  📈 Dashboards    ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │ Query APIs
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          DATA SOURCE BACKENDS                               │
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ PROMETHEUS  │  │    MIMIR    │  │    LOKI     │  │    TEMPO    │         │
│  │             │  │             │  │             │  │             │         │
│  │ PromQL API  │  │ PromQL API  │  │ LogQL API   │  │ TraceQL API │         │
│  │ /api/v1/    │  │ /api/v1/    │  │ /loki/api/  │  │ /api/v2/    │         │
│  │             │◄─┤             │◄─┤             │◄─┤             │         │
│  │ Short-term  │  │ Long-term   │  │ Log Aggr.   │  │ Distributed │         │
│  │ Metrics     │  │ Metrics     │  │ & Search    │  │ Tracing     │         │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘         │
│                                                                             │
│                           ┌─────────────┐                                   │
│                           │ PYROSCOPE   │                                   │
│                           │             │                                   │
│                           │ Pprof API   │◄─────────────────────────────────-┤
│                           │ /api/v1/    │                                   │
│                           │             │                                   │
│                           │ Continuous  │                                   │
│                           │ Profiling   │                                   │
│                           └─────────────┘                                   │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │ Data Collection
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       TELEMETRY AGGREGATION                                 │
│                    ┌─────────────────────────────────┐                      │
│                    │         GRAFANA ALLOY           │                      │
│                    │                                 │                      │
│                    │ • OTEL Receiver (4317/4318)     │                      │
│                    │ • Prometheus Scraper (9090)     │                      │
│                    │ • Log Processor & Router        │                      │
│                    │ • Trace Processor & Exporter    │                      │
│                    │ • Profile Collector & Forwarder │                      │
│                    └─────────────┬───────────────────┘                      │
│                                   │                                         │
│                    ┌──────────────┴───────────────┐                         │
│                    │         BEYLA (eBPF)         │                         │
│                    │  Auto-instrumentation for    │                         │
│                    │  RED metrics & traces        │                         │
│                    └──────────────────────────────┘                         │
└──────────────────────────────────┼──────────────────────────────────────────┘
                                   │ Telemetry Collection
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           KUBERNETES CLUSTER                                │
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ APPLICATION │  │ APPLICATION │  │ APPLICATION │  │OBSERVABILITY│         │
│  │   POD A     │  │   POD B     │  │   POD C     │  │  SERVICES   │         │
│  │             │  │             │  │             │  │             │         │
│  │ /metrics    │  │ /metrics    │  │ /metrics    │  │ ConfigMaps  │         │
│  │ stdout logs │  │ stdout logs │  │ stdout logs │  │ Services    │         │
│  │ OTEL traces │  │ OTEL traces │  │ OTEL traces │  │ Ingress     │         │
│  │ pprof/:6060 │  │ pprof/:6060 │  │ pprof/:6060 │  │ RBAC        │         │
│  │             │  │             │  │             │  │ Secrets     │         │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────────────────────┘

VISUALIZATION QUERIES:
======================
📊 Metrics Query:   Grafana → PromQL → Prometheus/Mimir
📝 Logs Query:      Grafana → LogQL  → Loki
🔗 Traces Query:    Grafana → TraceQL→ Tempo  
🔥 Profiles Query:  Grafana → Pprof  → Pyroscope

DATA COLLECTION FLOW:
=====================
Applications → Beyla/Alloy/Promtail → Storage Backends → Grafana Dashboards

GRAFANA DATASOURCES:
====================
┌─────────────────┬─────────────────┬──────────────────────────────────────┐
│ DATASOURCE      │ QUERY LANGUAGE  │ ENDPOINT                             │
├─────────────────┼─────────────────┼──────────────────────────────────────┤
│ Prometheus      │ PromQL          │ http://prometheus-server             │
│ Mimir           │ PromQL          │ http://mimir/prometheus              │
│ Loki            │ LogQL           │ http://loki:3100                     │
│ Tempo           │ TraceQL         │ http://tempo:3100                    │
│ Pyroscope       │ Pprof           │ http://pyroscope:4040                │
└─────────────────┴─────────────────┴──────────────────────────────────────┘
```

## Deployment

```shell
kubectl apply -k ./deployment
```

This will deploy the following services in `monitoring` namespace:

| Service    | Description                                                      |
|------------|------------------------------------------------------------------|
| Grafana    | Preconfigured with Prometheus, Mimir, Loki, Tempo, Pyroscope    |
| Prometheus | Metrics collection and short-term storage                       |
| Mimir      | Long-term metrics storage                                       |
| Loki       | Log aggregation and storage                                     |
| Alloy      | Telemetry collector, pushes to Prometheus, Mimir, Loki, Tempo, Pyroscope |
| Beyla      | eBPF-based auto-instrumentation, pushes to Alloy                |
| ~~Promtail~~ | Agent which ships the contents of local logs to Grafana Loki |
| Pyroscope  | Continuous profiling backend                                    |
| Tempo      | Distributed tracing backend                                     |

## Configuration

Once deployed, access Grafana UI via:

```shell
kubectl port-forward -n monitoring svc/grafana 3000:3000
```
> [!NOTE]
> If you deploy to different namespace, update `ClusterRoleBinding` subject namespace to match

Grafana open and composable [observability stack](https://grafana.com/about/grafana-stack/)

## Why make or use this?

This is an attempt to demystify the different components of [LGTM+ Stack](https://github.com/grafana/helm-charts/tree/main/charts), deploying the full stack can seem overwhelming, breaking it down to smaller composable pieces will hopefully help you better understand each service and its configuration.

## Source

Our latest and greatest source of **grafana-loki-on-k8s* can be found on [GitHub](https://github.com/saidsef/grafana-loki-on-k8s/fork), Fork us!

## Contributing

We would :heart: you to contribute by making a [pull request](https://github.com/saidsef/grafana-loki-on-k8s/pulls).

Please read the official [Contribution Guide](./CONTRIBUTING.md) for more information on how you can contribute.
