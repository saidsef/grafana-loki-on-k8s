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

Profiles arrive from two sources:

**Beyla eBPF** — when Pyroscope is included in the kustomization, Beyla's ConfigMap is patched to enable `otel_profiles_export`. Beyla collects CPU flame graphs from every process via eBPF perf events and pushes them directly to `http://pyroscope:4040`. No application changes or annotations required. If Pyroscope is later removed from the kustomization, the patch is not applied and Beyla stops profiling.

**Alloy pprof scraping** — for Go services, Alloy pulls pprof endpoints. A single annotation enables memory, CPU, and goroutine profiling:

```yaml
metadata:
  annotations:
    profiles.grafana.com/port: "8080"
```

Or with per-type control:

```yaml
metadata:
  annotations:
    profiles.grafana.com/cpu.scrape: "true"
    profiles.grafana.com/cpu.port:   "8080"
```

See [Alloy](./alloy.md#profiling) for the full annotation reference, opt-out syntax, and how the pipeline works.

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

- Pyroscope stores and serves profiles. Collection is handled by Alloy (pprof) and Beyla (eBPF).
- Trace-to-profile links from [Tempo](./tempo.md) are what tie profiles to the rest of the data.
- Any service shows up in CPU flame graphs automatically via Beyla eBPF. Go services get richer heap and goroutine profiles by adding pprof annotations.
- Pyroscope is optional. When not deployed, Alloy drops pprof profiles after a short retry window, and the Beyla patch is not applied so there is no wasted profiling overhead.
