# Kubernetes — Design Decisions

> These notes were generated with AI assistance (Claude), prompted to summarize key design decisions and their rationale as development progressed. All decisions reflect choices made during active development.

## Observability stack: Prometheus + Grafana on Fargate

Prometheus, Grafana, and Pushgateway all run as standard Kubernetes Deployments. No DaemonSets are used.

### Why no DaemonSet for Prometheus

The conventional Prometheus Agent deployment pattern uses a DaemonSet to run a scraping agent on every node, enabling node-local metric collection. DaemonSets are not supported on Fargate — AWS does not expose the underlying node to the pod scheduling layer, so there is no node to place a DaemonSet pod on.

This is not a blocker. The DaemonSet pattern exists primarily for node-level metrics via `node-exporter`. On Fargate, there are no nodes to manage, so node-level metrics are not applicable. Pod and application-level metrics are fully available through standard Kubernetes service discovery.

### How scraping works without a DaemonSet

Prometheus server runs in standard (non-agent) mode as a single Deployment. It uses `kubernetes_sd_configs` to discover pods and services via the Kubernetes API and scrapes their `/metrics` endpoints directly over the pod network. Service discovery goes through the K8s API — not node-local access — so it works on Fargate without modification.

### Stack layout

| Component | K8s workload type | Purpose |
|-----------|------------------|---------|
| Prometheus | Deployment | Metric scraping and storage via K8s service discovery |
| Grafana | Deployment | Dashboards and visualization |
| Pushgateway | Deployment | Receives metrics pushed by short-lived jobs (poller CronJob) |

The Pushgateway is the correct pattern for CronJob metrics. CronJob pods are short-lived and exit before Prometheus can scrape them on a standard interval. The poller pushes its metrics to the Pushgateway on completion; Prometheus scrapes the Pushgateway on its normal schedule.

## Planned decisions to document
- CronJob schedule and restart policy for poller
- Deployment configuration for API
- IRSA service account binding
- Alert configuration for poller CronJob health
- Resource requests/limits