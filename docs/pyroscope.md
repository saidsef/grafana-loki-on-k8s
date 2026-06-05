# Pyroscope

Pyroscope is the continuous-profiling backend. It is the odd one out in this stack: instead of receiving from Alloy, it ships its own embedded Alloy River config that scrapes profile endpoints off annotated pods and writes back to itself. Config lives in [`deployment/pyroscope/cm.yml`](../deployment/pyroscope/cm.yml).

## What it runs

- Deployment, single replica, image `docker.io/grafana/pyroscope:2.10.5`.
- Args: `-target=all -self-profiling.disable-push=true -server.http-listen-port=4040 -memberlist.cluster-label=pyroscope -memberlist.join=dns+pyroscope:7946 -config.file=/etc/pyroscope/config.yaml -runtime-config.file=/etc/pyroscope/overrides/overrides.yaml`.
- Ports: 4040 (HTTP, ingest and query), 9095 (gRPC), 7946 (memberlist).
- Resources: requests 100m CPU / 512Mi, limits 200m CPU / 768Mi.
- Storage: three 2 Gi emptyDirs at `/data`, `/data-compactor`, `/data-shared`.
- Security: non-root UID/GID 10001, read-only root filesystem, all caps dropped.
- RBAC: ClusterRole grants list/watch on pods and get on nodes, which is what the embedded discovery needs.

## Configuration

The main `config.yaml` is one line, telemetry off:

```yaml
analytics:
  reporting_enabled: false
```

`overrides.yaml` is empty. All the real configuration is in `config.river`, an Alloy River program the Pyroscope binary runs to do its own scraping.

Discovery is plain Kubernetes pod role:

```river
discovery.kubernetes "pyroscope_kubernetes" {
  role = "pod"
}
```

There are six `pyroscope.scrape` blocks, one per profile type, all gated on `profiles.grafana.com/<type>.scrape: "true"` annotations: `memory`, `process_cpu`, `goroutine`, `block`, `mutex`, `fgprof`. Each block looks like this (memory shown):

```river
pyroscope.scrape "pyroscope_scrape_memory" {
  clustering { enabled = true }
  targets    = concat(
    discovery.relabel.kubernetes_pods_memory_default_name.output,
    discovery.relabel.kubernetes_pods_memory_custom_name.output,
  )
  forward_to = [pyroscope.write.pyroscope_write.receiver]

  profiling_config {
    profile.memory      { enabled = true }
    profile.process_cpu { enabled = false }
    profile.goroutine   { enabled = false }
    profile.block       { enabled = false }
    profile.mutex       { enabled = false }
    profile.fgprof      { enabled = false }
  }
}
```

The relabel rules pick up `profiles.grafana.com/<type>.{port,port_name,scheme,path}` for each annotation family. Two relabel variants per type cover the `port` and `port_name` annotation styles.

Everything flows into one writer pointing at the Pyroscope service itself:

```river
pyroscope.write "pyroscope_write" {
  endpoint {
    url = "http://pyroscope:4040"
  }
}
```

Cluster membership is via memberlist, joined by DNS SRV lookup on the service:

```
-memberlist.join=dns+pyroscope:7946
```

With one replica the membership is a single member, but the config is ready to scale.

## Inputs

Pods opt in by adding annotations. For example, to scrape CPU profiles on port 8080:

```yaml
metadata:
  annotations:
    profiles.grafana.com/cpu.scrape: "true"
    profiles.grafana.com/cpu.port:   "8080"
```

The embedded scraper finds them, pulls the pprof endpoint and writes the result back to `http://pyroscope:4040`. No external collector is involved.

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
  query: 'method="$${__span.tags.method}"'
```

That is the path Grafana uses to jump from a slow span straight to the matching CPU flame graph.

## How it fits the stack

- Self-contained. Does not depend on [Alloy](./alloy.md) for ingest, but uses the same Alloy components internally.
- Trace-to-profile links from [Tempo](./tempo.md) are what tie profiles to the rest of the data.
- For an app to show up here, it has to expose pprof and add the right `profiles.grafana.com/*` annotations to its pod.
