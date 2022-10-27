# Grafana Loki

Loki is a horizontally-scalable, highly-available, multi-tenant log aggregation system inspired by Prometheus. It is designed to be very cost effective and easy to operate, as it does not index the contents of the logs, but rather a set of labels for each log stream.

## Prerequisites
- Kubernetes Cluster >= v1.22
- Kubectl CLI
- Familiarity with Grafana, Loki and Promtail

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
