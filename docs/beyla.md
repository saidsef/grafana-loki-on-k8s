# Beyla

Beyla is the eBPF auto-instrumentation agent. It inspects application executables and the OS networking layer directly, producing RED metrics and trace spans for HTTP/S and gRPC services without touching application code. Manifests live in [`deployment/beyla/`](../deployment/beyla/).

It runs as its own DaemonSet rather than inside [Alloy](./alloy.md). See [Why not `beyla.ebpf` in Alloy](#why-not-beylaebpf-in-alloy).

## What it runs

- DaemonSet, image `docker.io/grafana/beyla:3.30.0`, one pod per node.
- `hostPID: true` so Beyla can see and inspect processes in other containers' PID namespaces. Mandatory in DaemonSet mode.
- `hostNetwork: true` with `dnsPolicy: ClusterFirstWithHostNet`, required for the network-level context propagation described below.
- Health, readiness and liveness on port 9090 (`/healthz`).
- Resources: requests 50m CPU / 512Mi, limits 100m CPU / 768Mi.
- Exports metrics and traces to Alloy at `alloy:4317`, and profiles straight to `pyroscope:4040`.

## Privileges

Beyla runs unprivileged: `privileged: true` is deliberately absent, because it grants every capability, which would make the explicit list below decorative and stop `enforce_sys_caps: true` from ever firing. Instead all capabilities are dropped and eight are added back:

| Capability | Why |
|---|---|
| `BPF` | Required for most eBPF probes to function. |
| `SYS_PTRACE` | Access other containers' namespaces and inspect executables. |
| `NET_RAW` | Socket filters for HTTP requests. |
| `CHECKPOINT_RESTORE` | Open ELF files. |
| `DAC_READ_SEARCH` | Open ELF files. |
| `PERFMON` | Load BPF programs. |
| `NET_ADMIN` | Inject HTTP and TCP context propagation information. |
| `SYS_ADMIN` | User-space probes, and any host with `kernel.perf_event_paranoid >= 3`. |

`SYS_ADMIN` is not optional on the production node: it reports `perf_event_paranoid = 4`. Dropping `privileged` without adding `SYS_ADMIN` would stop Beyla loading probes. That node also sets `unprivileged_bpf_disabled = 1`, which makes `CAP_BPF` mandatory.

`readOnlyRootFilesystem: true` and `runAsUser: 0` are both required — the host bpffs is mounted `mode=700`, so only root can traverse it.

## Host mounts

| Mount | Why |
|---|---|
| `/sys/fs/cgroup` (read-only) | Track newly created sockets for outgoing requests. |
| `/sys/kernel/tracing` | Required from Beyla 3.28.0 — context propagation now uses normal tracepoints. |
| `/sys/fs/bpf` | Must be a **real bpffs**, not just a directory. |

The bpffs mount uses `mountPropagation: HostToContainer`, and that is load-bearing. Beyla defaults `bpf_fs_path` to `/sys/fs/bpf` and calls `MkdirAll` on `/sys/fs/bpf/otel`. If that path is plain sysfs rather than a mounted bpffs, the call fails, and Beyla logs a warning and then **silently disables every pinned map** — which it documents as disabling the log enricher and profile correlation. It does not crash.

On the production node the bpffs is mounted by *Cilium*, not by systemd (`sys-fs-bpf.mount` is inactive). Because a pod provides the mount, boot ordering against the Beyla DaemonSet is not guaranteed. Without `HostToContainer`, a Beyla that starts before cilium-agent captures the read-only sysfs view and never sees the bpffs that appears later.

If profiles or correlation go missing, check for this in the Beyla logs:

```
creating OTEL namespace in bpffs failed (is bpffs mounted?)
```

## Discovery

`discovery.instrument` and `discovery.exclude_instrument` match by **glob**, not regex. The older `discovery.services` / `exclude_services` keys are regex — the two families differ, and mixing them up fails silently: Beyla instruments nothing, logs nothing at `WARN`, and Alloy's `otelcol_receiver_accepted_*` counters simply stay at zero.

```yaml
discovery:
  instrument:
    - k8s_namespace: "*"      # "*" matches all namespaces; "." would match only a literal "."
      containers_only: true
  exclude_instrument:
    - exe_path: "{*tempo*,*loki*,*prometheus*,*mimir*,*grafana*}"
```

The stack's own backends are excluded to avoid instrumenting the observability plumbing. Beyla additionally self-excludes by default (`*beyla`, `*alloy`, `*otelcol`, `*obi` and similar).

To diagnose a silent no-op, set `log_level: DEBUG` and look for:

```
msg="metadata does not match" attr=k8s_namespace value=<namespace>
```

## Metrics features

`application` and `application_span_otel` are enabled. `application_service_graph` is deliberately omitted: Beyla emits the same `traces_service_graph_*` metric names as Tempo's generator but with extra labels, and Grafana sums by `(client, server)`, merging the two into one misleading series. [Tempo](./tempo.md) owns the service graph. See #269.

`network` is disabled. Network-level metrics require Beyla to generate a metric per flow, which raises CPU and memory materially, and the RED metrics above already cover the questions being asked of this stack.

## Profiles

`otel_profiles_export` is enabled unconditionally and pushes to `pyroscope:4040` over OTLP gRPC. This bypasses Alloy entirely — Alloy's `otelcol.receiver.otlp` carries no profiles signal. If [Pyroscope](./pyroscope.md) is removed from the kustomization, Beyla keeps collecting and drops each batch after its 30-second retry window; it does not stop profiling. See [Pyroscope](./pyroscope.md) for the full profiling picture.

## Why not `beyla.ebpf` in Alloy

Alloy ships a `beyla.ebpf` component that would fold this DaemonSet into the Alloy one. It is not used here:

- Alloy's embedded Beyla is several versions behind the standalone image. The tracefs mount above, needed from 3.28.0, is not in it.
- The component requires Alloy to run with administrative privileges (or the same capability list), plus `hostPID: true` and an **Unconfined** AppArmor profile. Alloy currently runs unprivileged with all capabilities dropped, and it carries every log, metric, trace and profile pipeline in the stack — a much larger blast radius.
- Beyla needs `hostNetwork: true` for context propagation, which would collide with Alloy's ports 4317, 4318 and 12345 on every node.
