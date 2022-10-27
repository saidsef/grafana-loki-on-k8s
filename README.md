# Grafana, Prometheus, Loki and Promtail

[Loki](https://grafana.com/oss/loki/) is a horizontally-scalable, highly-available, multi-tenant log aggregation system inspired by Prometheus. It is designed to be very cost effective and easy to operate, as it does not index the contents of the logs, but rather a set of labels for each log stream.

[Promtail](https://grafana.com/docs/loki/latest/clients/promtail/) is an agent which ships the contents of local logs to a private Grafana Loki instance or Grafana Cloud. It is usually deployed to every machine that has applications needed to be monitored.

I am assuming you are already familiar with [Grafana](https://grafana.com/oss/grafana/) and [Prometheus](https://prometheus.io/docs/prometheus/latest/getting_started/)

## Prerequisites
- Kubernetes Cluster >= v1.22
- Familiarity with Grafana, Prometheus, Loki and Promtail

## Deployment

```shell
kubectl apply -k ./deployment
```

This will deploy the following services in `monitoring` namespace:

- Grafana - with Prometheus and Loki as data sources
- Prometheus
- Loki
- Promtail - with configuration that will push data to Loki

## Configuration

Once deployed, access Grafana UI via:

```shell
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

Here is [how to guide from Grafana / Loki](https://grafana.com/docs/loki/latest/)

## Why make or use this?

This is an attempt to demystify the different components of [Loki Stack](https://github.com/grafana/helm-charts), deploying the full stack can seem overwhelming, breaking it down to smaller composable pieces will hopefully help you better understand each service and its configuration.

## Source

Our latest and greatest source of grafana-loki-on-k8s can be found on [GitHub]. Fork us!

## Contributing

We would :heart: you to contribute by making a [pull request](https://github.com/saidsef/grafana-loki-on-k8s/pulls).

Please read the official [Contribution Guide](./CONTRIBUTING.md) for more information on how you can contribute.
