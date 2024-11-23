# Grafana, Prometheus, Loki, Promtail, Tempo, Pyroscope and Mimir (LGTM)

[Loki](https://grafana.com/oss/loki/) is a horizontally-scalable, highly-available, multi-tenant log aggregation system inspired by Prometheus. It is designed to be very cost effective and easy to operate, as it does not index the contents of the logs, but rather a set of labels for each log stream.

[Promtail](https://grafana.com/docs/loki/latest/clients/promtail/) is an agent which ships the contents of local logs to a private Grafana Loki instance or Grafana Cloud. It is usually deployed to every machine that has applications needed to be monitored.

[Tempo](https://grafana.com/oss/tempo/) is an open source, easy-to-use, and high-scale distributed tracing backend. Tempo is cost-efficient, requiring only object storage to operate, and is deeply integrated with Grafana, Prometheus, and Loki. Tempo can ingest common open source tracing protocols, including Jaeger, Zipkin, and OpenTelemetry.

[Mimir](https://grafana.com/oss/mimir/) lets you scale metrics to 1 billion active series and beyond, with high availability, multi-tenancy, durable storage, and blazing fast query performance over long periods of time.

[Pyroscope](https://grafana.com/docs/pyroscope/latest/) is a multi-tenant, continuous profiling aggregation system, aligning its architectural design with Grafana Mimir, Grafana Loki, and Grafana Tempo. This integration enables a cohesive correlation of profiling data with existing metrics, logs, and traces.

I am assuming you are already familiar with [Grafana](https://grafana.com/oss/grafana/) and [Prometheus](https://prometheus.io/docs/prometheus/latest/getting_started/)

## Prerequisites
- Kubernetes Cluster >= v1.26
- Familiarity with Grafana, Prometheus, Loki, Promtail, Tempo and Mimir
- ...
- Profit?

## Deployment

```shell
kubectl apply -k ./deployment
```

This will deploy the following services in `monitoring` namespace:

- Grafana - preconfigured with Prometheus, Loki and Tempo as data sources
- Prometheus
- Loki
- Promtail - preconfigured to push data to Loki
- Tempo

## Configuration

Once deployed, access Grafana UI via:

```shell
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

Here is [how to guide from Grafana / Loki](https://grafana.com/docs/loki/latest/)

## Why make or use this?

This is an attempt to demystify the different components of [LGTM Stack](https://github.com/grafana/helm-charts/tree/main/charts), deploying the full stack can seem overwhelming, breaking it down to smaller composable pieces will hopefully help you better understand each service and its configuration.

## Source

Our latest and greatest source of grafana-loki-on-k8s can be found on [GitHub]. Fork us!

## Contributing

We would :heart: you to contribute by making a [pull request](https://github.com/saidsef/grafana-loki-on-k8s/pulls).

Please read the official [Contribution Guide](./CONTRIBUTING.md) for more information on how you can contribute.
