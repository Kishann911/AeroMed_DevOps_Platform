# AeroMed Platform — Monitoring Guide

## Overview

The AeroMed monitoring stack consists of three components:

| Component | URL | Purpose |
|-----------|-----|---------|
| **Prometheus** | http://localhost:9090 | Metrics collection, alert evaluation, query engine |
| **Grafana** | http://localhost:3000 | Visualisation dashboards (admin / aeromed123) |
| **AlertManager** | http://localhost:9093 | Alert routing, deduplication, silencing |

---

## Grafana Dashboards

### 1. AeroMed Operations Overview (`/d/aeromed-operations-overview`)

The primary on-call dashboard. Open this first during any incident.

| Panel | What it shows | Alert threshold |
|-------|---------------|----------------|
| Platform Health | Count of healthy services (0–6) | Red < 4, Yellow 4–5, Green 6 |
| Active Emergencies | `aeromed_emergency_dispatch_active_count` | Always red (urgency indicator) |
| Aircraft in Transit | `aeromed_flights_active_count` | Green 0–3, Yellow 4–6, Red 7+ |
| SLO — Availability | Min avg uptime across all services (1h) | Red <99%, Yellow 99–99.9%, Green ≥99.9% |
| Service Response Times | p95 latency per service | Alert line at 2.0s |
| Request Rate per Service | req/s (5m window) per service | Visual reference |
| Pod Status | Per-pod phase, ready state, restart count | Color by phase (Running=green) |
| Error Rate | HTTP 5xx rate per service | Red fill above 5% |
| Active Alerts | Currently firing AlertManager alerts | Live feed |

**Key variable:** Service selector dropdown allows filtering all panels to a single service.

### 2. AeroMed Service Deep Dive (`/d/aeromed-service-health`)

One row per service with four panels each:
- **Uptime %** (stat) — availability over the selected time range
- **Response Time Distribution** (heatmap) — shows latency spread at a glance
- **Request Rate** (time series) — throughput in req/s
- **Error Rate** (time series, red fill) — HTTP 5xx percentage

Use this dashboard to investigate a specific service after the operations overview flags an issue.

### 3. AeroMed Infrastructure (`/d/aeromed-infrastructure`)

Infrastructure and Kubernetes internals:
- Node CPU and memory utilisation
- Container CPU % of limit (gauge, per pod)
- Container memory % of limit (gauge, per pod)
- Deployment availability ratio (table)
- Ready replicas per deployment (time series)
- HPA current / min / max replicas (time series, shows scaling events)
- Node network receive/transmit rate

---

## Prometheus Metrics Reference

### Custom AeroMed Metrics

| Metric | Labels | Description |
|--------|--------|-------------|
| `aeromed_emergency_dispatch_active_count` | — | Active emergency dispatches right now |
| `aeromed_flights_active_count` | — | Aircraft currently airborne on patient transport |
| `aeromed:requests_per_second` | `job` | Recording rule: per-service request rate |
| `aeromed:error_rate` | `job` | Recording rule: per-service error rate (5xx/total) |

### Standard Metrics (all services export these)

| Metric | Type | Description |
|--------|------|-------------|
| `up` | gauge | 1 if Prometheus can scrape the target, 0 if not |
| `http_requests_total` | counter | HTTP requests by method, status, endpoint |
| `response_time_seconds_bucket` | histogram | Request latency histogram (for percentile calculation) |
| `process_resident_memory_bytes` | gauge | RSS memory of the service process |
| `process_cpu_seconds_total` | counter | CPU time consumed |

### Useful Prometheus Queries

```promql
# Count of healthy services
count(up{job=~"aeromed-.*"} == 1)

# p95 latency for emergency-dispatch
histogram_quantile(0.95,
  rate(response_time_seconds_bucket{job="aeromed-emergency-dispatch"}[5m])
)

# Error rate for all services
rate(http_requests_total{job=~"aeromed-.*", status=~"5.."}[5m])
/ rate(http_requests_total{job=~"aeromed-.*"}[5m])

# HPA replica count (Kubernetes)
kube_horizontalpodautoscaler_status_current_replicas{namespace="aeromed-production"}

# Pod restart count (detect crash loops)
kube_pod_container_status_restarts_total{namespace="aeromed-production"}

# Pod not ready
kube_pod_status_ready{namespace="aeromed-production"} == 0

# Platform-wide availability (1h window)
min(avg_over_time(up{job=~"aeromed-.*"}[1h])) * 100
```

---

## Alerts Reference

Alerts are defined in `monitoring/prometheus/alert-rules.yml`.

### Tier 1 Alerts (P1 — immediate)

| Alert | Condition | Severity | Receiver |
|-------|-----------|----------|---------|
| `AircraftCommunicationLost` | `up{job="aeromed-aircraft-comms"} == 0` for 1m | critical | aeromed-flight-ops-team |
| `EmergencyDispatchDown` | `up{job="aeromed-emergency-dispatch"} == 0` for 1m | critical | aeromed-critical-ops |
| `FlightOperationsDown` | `up{job="aeromed-flight-operations"} == 0` for 1m | critical | aeromed-critical-ops |
| `ClusterDown` | `count(up{job=~"aeromed-.*"} == 0) >= 3` | critical | aeromed-critical-ops |

### Tier 2 Alerts (P2 — respond within 15 min)

| Alert | Condition | Severity | Receiver |
|-------|-----------|----------|---------|
| `MedicalRecordsServiceUnavailable` | `up{job="aeromed-patient-records"} == 0` for 2m | critical | aeromed-medical-team |
| `MedicalEquipmentDown` | `up{job="aeromed-medical-equipment"} == 0` for 2m | warning | aeromed-devops-team |
| `HighErrorRate` | `aeromed:error_rate > 0.05` for 5m | warning | aeromed-devops-team |

### Performance Alerts

| Alert | Condition | Severity | Receiver |
|-------|-----------|----------|---------|
| `HighLatency` | `p95 latency > 2s` for 5m | warning | aeromed-devops-team |
| `HPAAtMaxReplicas` | HPA current == max for 10m | warning | aeromed-devops-team |
| `PodCrashLooping` | Restart count > 5 in 15m | warning | aeromed-devops-team |
| `PodPending` | Pod in Pending state > 5m | warning | aeromed-devops-team |

---

## AlertManager Routing

```
Incoming alert
    │
    ├── severity=critical  ──► aeromed-critical-ops
    │                          (Slack #aeromed-critical-alerts + email ops-critical@aeromed.com)
    │                          group_wait: 0s (immediate)
    │                          repeat: every 5 minutes
    │
    ├── alertname=AircraftCommunicationLost
    │                     ──► aeromed-flight-ops-team
    │                          (Slack #flight-operations + email flight-ops@aeromed.com)
    │                          group_wait: 0s
    │
    ├── alertname=MedicalRecordsServiceUnavailable
    │                     ──► aeromed-medical-team
    │                          (Slack #medical-ops + email medical-ops@aeromed.com)
    │                          group_wait: 0s
    │
    ├── severity=warning  ──► aeromed-devops-team
    │                          (Slack #aeromed-devops)
    │                          group_wait: 30s (de-duplicate flapping)
    │
    └── (default)         ──► aeromed-default
                               (Slack #aeromed-monitoring)
```

**Inhibit rule:** If a `critical` alert fires for a service, all `warning` alerts for the same service are suppressed — prevents alert noise during an active incident.

---

## SLO Monitoring

| SLO | Target | Prometheus Query |
|-----|--------|-----------------|
| Platform availability | 99.9% (30-day rolling) | `min(avg_over_time(up{job=~"aeromed-.*"}[30d])) * 100` |
| Emergency-dispatch p99 latency | < 500ms | `histogram_quantile(0.99, rate(response_time_seconds_bucket{job="aeromed-emergency-dispatch"}[5m]))` |
| Overall error rate | < 0.1% | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` |

---

## On-Call Runbook Quick Reference

```
Alert fires in PagerDuty
        │
        ├─ 1. Open Operations Overview: http://localhost:3000/d/aeromed-operations-overview
        │
        ├─ 2. Identify degraded service (Platform Health panel)
        │
        ├─ 3. Open relevant runbook:
        │     Service failure:          disaster-recovery/runbooks/RB-001-service-failure.md
        │     CrashLoop:               disaster-recovery/runbooks/RB-002-pod-crashloop.md
        │     Aircraft comms:          disaster-recovery/runbooks/RB-003-aircraft-comms-loss.md
        │     Database:               disaster-recovery/runbooks/RB-004-database-failure.md
        │     Full cluster:           disaster-recovery/runbooks/RB-005-full-cluster-failure.md
        │     Traffic surge:          disaster-recovery/runbooks/RB-006-traffic-surge.md
        │
        └─ 4. Run health check to confirm: ./disaster-recovery/scripts/health-check-all.sh
```

---

## Adding a New Alert

1. Edit `monitoring/prometheus/alert-rules.yml`:

```yaml
- alert: MyNewAlert
  expr: <prometheus_query>
  for: 5m
  labels:
    severity: warning
    service: my-service
  annotations:
    summary: "Short description for Slack title"
    description: "Longer description with context: {{ $value }}"
    runbook: "https://wiki.aeromed.internal/runbooks/RB-XXX"
```

2. Reload Prometheus (no restart needed):
```bash
curl -X POST http://localhost:9090/-/reload
```

3. Test the alert rule:
```bash
curl -s "http://localhost:9090/api/v1/rules" | \
  python3 -c "import sys,json; [print(r['name'], r.get('health','?')) for g in json.load(sys.stdin)['data']['groups'] for r in g['rules']]"
```

4. Add routing in `monitoring/alertmanager/alertmanager.yml` if the new alert needs a non-default receiver.
