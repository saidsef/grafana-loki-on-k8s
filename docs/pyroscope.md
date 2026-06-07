# Pyroscope

Pyroscope is the continuous-profiling backend. Profile scraping is handled by [Alloy](./alloy.md) — pods opt in via annotations and Alloy pulls their pprof endpoints and forwards to Pyroscope. Config lives in [`deployment/pyroscope/cm.yml`](../deployment/pyroscope/cm.yml).

## What it runs

- Deployment, single replica, image `docker.io/grafana/pyroscope:2.10.5`.
- Args: `-config.file=/etc/pyroscope/config.yaml -runtime-config.file=/etc/pyroscope/overrides/overrides.yaml -log.level=info`. All other configuration is in `config.yaml` — log level is the one flag Pyroscope does not expose in the config file.
- Ports: 4040 (HTTP, ingest and query), 9095 (gRPC), 7946 (memberlist).
- Resources: requests 100m CPU / 512Mi, limits 200m CPU / 768Mi.
- Storage: one emptyDir (2 Gi) at `/data`, `/data-compactor`, `/data-shared`; one emptyDir (1 Gi) at `/tmp` for compactor scratch space.
- Security: non-root UID/GID 10001, read-only root filesystem, all caps dropped.

## Configuration

`config.yaml` is the single source of truth for all Pyroscope behaviour. Only the two file-path bootstrapping flags and log level remain as CLI args — log level cannot be set in the config file in Pyroscope 2.x.

```yaml
target: all

analytics:
  reporting_enabled: false

self_profiling:
  disable_push: true

server:
  http_listen_port: 4040

memberlist:
  cluster_label: pyroscope
  join_members:
    - dns+pyroscope:7946
```

`overrides.yaml` is empty — it is the runtime config file for per-tenant limit overrides.

Cluster membership is via memberlist gossip using DNS SRV lookup on the service. With one replica the membership is a single member, but the config is ready to scale.

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
