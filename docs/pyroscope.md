# Pyroscope

Pyroscope is the continuous-profiling backend. Profile scraping is handled by [Alloy](./alloy.md) — pods opt in via annotations and Alloy pulls their pprof endpoints and forwards to Pyroscope. Config lives in [`deployment/pyroscope/cm.yml`](../deployment/pyroscope/cm.yml).

## What it runs

- Deployment, single replica, image `docker.io/grafana/pyroscope:2.10.5`.
- Args: `-target=all -self-profiling.disable-push=true -server.http-listen-port=4040 -memberlist.cluster-label=pyroscope -memberlist.join=dns+pyroscope:7946 -config.file=/etc/pyroscope/config.yaml -runtime-config.file=/etc/pyroscope/overrides/overrides.yaml`.
- Ports: 4040 (HTTP, ingest and query), 9095 (gRPC), 7946 (memberlist).
- Resources: requests 100m CPU / 512Mi, limits 200m CPU / 768Mi.
- Storage: one emptyDir (2 Gi) mounted at three paths: `/data`, `/data-compactor` and `/data-shared`.
- Security: non-root UID/GID 10001, read-only root filesystem, all caps dropped.

## Configuration

`config.yaml` disables telemetry reporting and makes a few settings explicit that are otherwise also set via CLI flags:

```yaml
analytics:
  reporting_enabled: false

log_level: info

self_profiling:
  disable_push: true
```

`overrides.yaml` is empty — it is the runtime config file for per-tenant limit overrides.

Cluster membership is via memberlist, joined by DNS SRV lookup on the service:

```
-memberlist.join=dns+pyroscope:7946
```

With one replica the membership is a single member, but the config is ready to scale.

## Inputs

Pods opt in by adding annotations per profile type. For example, to scrape CPU profiles on port 8080:

```yaml
metadata:
  annotations:
    profiles.grafana.com/cpu.scrape: "true"
    profiles.grafana.com/cpu.port:   "8080"
```

Alloy discovers these pods and pushes the profiles to `http://pyroscope:4040`. See [Alloy](./alloy.md#profiling) for the full annotation reference and how the pipeline works.

## Outputs

Grafana reads Pyroscope at `http://pyroscope:4040/`:

```yaml
- name: Pyroscope
  type: grafana-pyroscope-datasource
  url: http://pyroscope:4040/
  jsonData:
    minStep: '15s'
```

The [Tempo](./tempo.md) data source also references Pyroscope through `tracesToProfiles`, joined on `job`, `instance`, `pod` and `namespace`:

```yaml
tracesToProfiles:
  datasourceUid: Pyroscope
  tags: ['job', 'instance', 'pod', 'namespace']
  profileTypeId: 'process_cpu:cpu:nanoseconds:cpu:nanoseconds'
  customQuery: true
  query: 'method="${__span.tags.method}"'
```

That is the path Grafana uses to jump from a slow span straight to the matching CPU flame graph.

## How it fits the stack

- Pyroscope stores and serves profiles. Scraping is entirely Alloy's responsibility.
- Trace-to-profile links from [Tempo](./tempo.md) are what tie profiles to the rest of the data.
- For an app to show up here, it has to expose pprof and add the right `profiles.grafana.com/*` annotations to its pod.
- Pyroscope is optional in this stack. When not deployed, Alloy drops profiles cleanly after a short retry window rather than accumulating a WAL backlog.
