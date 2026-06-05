# Grafana

Grafana is the visualisation layer. It runs a single replica, mounts five provisioned data sources (Mimir, Prometheus, Loki, Tempo, Pyroscope), serves the UI on `:3000`, and pre-installs 32 plugins on first start. Config lives in [`deployment/grafana/cm.yml`](../deployment/grafana/cm.yml).

The cross-data-source linking (logs to traces, traces to logs / metrics / profiles, service map) is all defined here, not in the backends.

## What it runs

- Deployment, single replica, image `docker.io/grafana/grafana:13.0.1`.
- Port: 3000 (HTTP). Service `grafana` exposes the same port.
- Resources: requests 50m CPU / 512Mi, limits 100m CPU / 768Mi. `GOMAXPROCS` and `GOMEMLIMIT` are bound to those limits via `resourceFieldRef`.
- Storage: 4 Gi emptyDir at `/var/lib/grafana`, split by subPath into `grafana` (state), `dashboards` (provisioned dashboards) and `tmp`.
- Security: non-root UID/GID 65534, read-only root filesystem, all caps dropped, `RuntimeDefault` seccomp profile, `automountServiceAccountToken: false`.
- ConfigMaps mounted in: `dashboards` (provider config), `datasources` (one file per backend), `grafana-ini` (the main `grafana.ini`).
- Scraped by Prometheus through the pod annotations `prometheus.io/scrape: "true"` and `prometheus.io/port: "3000"`.

## Configuration

The three ConfigMaps map onto three concerns: how Grafana boots (`grafana.ini`), where it gets data (`datasources`) and where dashboards come from (`dashboards`).

### `grafana.ini`

```ini
instance_name=${HOSTNAME}
[explore]
enabled=true
[log]
mode = console
level = warn
[log.console]
format = json
[feature_toggles]
enable=true
alertRuleRestore=true
azureMonitorLogsBuilderEditor=true
elasticsearchCrossClusterSearch=true
externalServiceAccounts=true
faroDatasourceSelector=true
grafanaAdvisor=true
logsPanelControls=true
nestedFolders=false
panelTitleSearch=true
provisioning=true
kubernetesDashboards=true
pdfTables=true
sqlDatasourceDatabaseSelection=true
[feature_management]
allow_editing=true
[plugins]
enable_alpha=true
plugin_admin_enabled=true
preinstall_async=false
preinstall=<comma-separated plugin slugs, see Plugins below>
```

Notable choices: Explore is on, alpha plugins are allowed, the plugin admin UI is enabled, and the preinstall is synchronous (`preinstall_async=false`) so the pod will not report ready until all 32 plugins are downloaded.

### Dashboards provisioning

```yaml
apiVersion: 1
providers:
  - name: default
    type: file
    allowUiUpdates: false
    disableDeletion: false
    editable: true
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

The dashboards directory is an emptyDir, so nothing ships pre-loaded. Drop JSON files into the `dashboards` subPath of the PVC (or extend the `dashboards` ConfigMap) and Grafana will pick them up within 10 seconds.

### Data sources

Five files in the `datasources` ConfigMap, one per backend. The full blocks live in [`deployment/grafana/cm.yml`](../deployment/grafana/cm.yml). Summary:

| Data source | Type | URL | Notes |
|---|---|---|---|
| Mimir | `prometheus` | `http://mimir/prometheus` | `isDefault: true`, `prometheusType: Mimir`, exemplar `trace_id` jumps to Tempo |
| Prometheus | `prometheus` | `http://prometheus-server` | Same exemplar wiring as Mimir |
| Loki | `loki` | `http://loki:3100` | `derivedFields` rule extracts `"trace_id":"..."` and links to Tempo |
| Tempo | `tempo` | `http://tempo:3100` | Defines `tracesToLogsV2` (Loki), `tracesToMetrics` (Mimir), `tracesToProfiles` (Pyroscope), `serviceMap` (Mimir) |
| Pyroscope | `grafana-pyroscope-datasource` | `http://pyroscope:4040/` | `minStep: '15s'` |

The cross-jumps in the Tempo data source are what stitch the stack together in the UI. For example:

```yaml
tracesToProfiles:
  datasourceUid: Pyroscope
  tags: ['job', 'instance', 'pod', 'namespace']
  profileTypeId: 'process_cpu:cpu:nanoseconds:cpu:nanoseconds'
  customQuery: true
  query: 'method="$${__span.tags.method}"'
```

## Inputs

Grafana queries the five backends listed above. None of them push to Grafana. The data sources are provisioned from disk, not the UI, so any change requires editing [`deployment/grafana/cm.yml`](../deployment/grafana/cm.yml) and re-applying.

## Outputs

Grafana itself does not push data anywhere. It serves the UI on `:3000` and exposes its own metrics on the same port (scraped by Prometheus via the pod annotations).

Reach the UI locally with:

```shell
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

No Ingress is shipped in this repo, so exposing it externally is on you.

## Plugins

The Grafana ConfigMap sets `[plugins] preinstall=` so the listed plugins are downloaded and installed on Grafana start-up. There are 32 plugins in total, 26 published by Grafana Labs and 6 by community or third-party developers.

For the canonical plugin page (versions, screenshots, install size, signatures, source), substitute the slug into:

```
https://grafana.com/grafana/plugins/<slug>/
```

### Grafana Labs

Plugins signed by Grafana Labs.

| Slug | Name | What it does |
|------|------|--------------|
| `aws-datasource-provisioner-app` | AWS Data Sources | Provisions data sources for the various AWS services that have Grafana plugins. |
| `grafana-advisor-app` | Advisor | Runs diagnostic checks against your Grafana instance and surfaces issues for administrators. |
| `grafana-assistant-app` | Grafana Assistant | AI-powered observability agent for Grafana Cloud that takes natural-language questions about monitoring and troubleshooting. |
| `grafana-bigquery-datasource` | Google BigQuery | Queries and visualises data held in Google BigQuery. |
| `grafana-cloudflare-datasource` | Cloudflare | Queries and visualises data from Cloudflare. |
| `grafana-databricks-datasource` | Databricks | Direct connection to Databricks for querying and visualising Databricks data. |
| `grafana-dynamodb-datasource` | DynamoDB | Direct connection to DynamoDB with PartiQL query support. |
| `grafana-enterprise-logs-app` | Enterprise Logs (GEL) | Management app for Grafana Enterprise Logs clusters, tenants, access control, cluster health. |
| `grafana-enterprise-traces-app` | Enterprise Traces (GET) | Management app for Grafana Enterprise Traces clusters, tenants, access control, cluster health. |
| `grafana-exploretraces-app` | Traces Drilldown | Queryless investigation of Tempo traces using RED metrics, no TraceQL knowledge needed. |
| `grafana-github-datasource` | GitHub | Queries the GitHub API to visualise repositories, issues, pull requests, and projects. |
| `grafana-gitlab-datasource` | GitLab | Pulls GitLab data directly into Grafana dashboards. |
| `grafana-googlesheets-datasource` | Google Sheets | Visualises Google Sheets data inside Grafana dashboards. |
| `grafana-graphviz-panel` | Graphviz Panel | Renders Graphviz DOT graphs with live metrics from any Grafana data source. |
| `grafana-llm-app` | LLM | Centralises LLM API access for Grafana, stores keys, proxies requests, and powers AI features such as panel explanations. |
| `grafana-lokiexplore-app` | Logs Drilldown | Queryless browser for Loki logs, no LogQL required. |
| `grafana-lokioperational-app` | Loki-Operational | Admin-only operational console for Loki clusters, rings, storage, tenants. |
| `grafana-metrics-enterprise-app` | Enterprise Metrics (GEM) | Management app for Grafana Enterprise Metrics (Mimir-based) clusters. |
| `grafana-metricsdrilldown-app` | Metrics Drilldown | Queryless browser for Prometheus-compatible metrics, finds related series without PromQL. |
| `grafana-oncall-app` | OnCall | On-call rotations, escalation policies, and multi-channel alert routing including Slack, voice, and SMS. |
| `grafana-opensearch-datasource` | OpenSearch | Queries OpenSearch and Elasticsearch instances. |
| `grafana-pyroscope-app` | Profiles Drilldown | Queryless browse of Pyroscope continuous-profiling data with AI-assisted flame graph analysis. |
| `grafana-resourcesexporter-app` | Resources Exporter | Exports Grafana resources from an instance or Grafana Cloud account as Terraform, Grizzly, or Crossplane definitions. |
| `grafana-sentry-datasource` | Sentry | Queries and visualises Sentry error data. |
| `grafana-synthetic-monitoring-app` | Synthetic Monitoring | Blackbox monitoring, schedules availability, performance, and correctness checks against external targets from worldwide probes. |
| `grafana-x-ray-datasource` | AWS Application Signals | AWS application-observability data source. Renamed from "X-Ray" in v2.16.0, the slug is unchanged. |

### Community / third-party

Plugins published outside Grafana Labs. The `Publisher` column names who signs and maintains each one.

| Slug | Publisher | What it does |
|------|-----------|--------------|
| `computest-cloudwatchalarm-datasource` | Joris van der Wel | Queries the current state of AWS CloudWatch alarms. |
| `googlecloud-logging-datasource` | GCP Logging team | Backend data source for querying and visualising Google Cloud Logs. |
| `googlecloud-trace-datasource` | GCP Trace team | Backend data source for querying and visualising Google Cloud Trace spans. |
| `redis-explorer-app` | RedisGrafana | Connects to Redis Enterprise software clusters over REST API to provide configuration dashboards and data-source management. |
| `victoriametrics-logs-datasource` | VictoriaMetrics | Queries VictoriaLogs, a high-performance log store. |
| `victoriametrics-metrics-datasource` | VictoriaMetrics | Queries VictoriaMetrics, a high-performance metrics store. |

## How it fits the stack

- Reads from [Mimir](./mimir.md), [Prometheus](./prometheus.md), [Loki](./loki.md), [Tempo](./tempo.md) and [Pyroscope](./pyroscope.md). Writes nothing.
- The Tempo data source is the centre of the cross-jumps: a span links out to logs, metrics and profiles from one place.
- Plugin install runs synchronously at start. If a new plugin is added to the `preinstall` list, the pod will take longer to become ready on the next rollout.
