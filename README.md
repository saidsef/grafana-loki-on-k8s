# Grafana Loki

Loki is a horizontally-scalable, highly-available, multi-tenant log aggregation system inspired by Prometheus. It is designed to be very cost effective and easy to operate, as it does not index the contents of the logs, but rather a set of labels for each log stream.

## Prerequisites
 - Git
 - Kubernetes Cluster
 - Kubectl CLI

# Deployment

```shell

kubectl apply -f ./

```

# Configuration

Once all the services have been deployed and are up and running, access `Grafana Lofin Dashboard` via `Grafana Service - kubectl get svc -n logs`

Create `Loki` datasource, URL address is `http://loki:3100` and then select explore from right hand menu.

Here is [how to guide from Grafana](https://github.com/grafana/loki/blob/master/docs/usage.md)
