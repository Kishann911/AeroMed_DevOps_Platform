# AeroMed RTO / RPO Definitions and Measurements

## Definitions

**RTO (Recovery Time Objective):** The maximum acceptable time between a failure event and full service restoration. Exceeding RTO means patient/operational impact is occurring.

**RPO (Recovery Point Objective):** The maximum acceptable data loss measured in time. An RPO of 15 minutes means the system can tolerate losing at most 15 minutes of transactions.

---

## RTO Targets by Tier

| Tier | Services | RTO Target | Rationale |
|------|----------|------------|-----------|
| 1 | flight-operations, emergency-dispatch, aircraft-comms | **5 min** | Active aircraft and emergencies cannot be left unmanaged |
| 2 | patient-records, medical-equipment | **15 min** | Patient records needed for clinical decisions; crews can work from memory short-term |
| 3 | api-gateway, monitoring | **30 min** | Operational inconvenience; no direct patient safety impact |

## RPO Target

| Component | RPO Target | Mechanism |
|-----------|------------|-----------|
| Application state (K8s configs) | **0 min** | GitOps — manifests are source of truth in Git |
| Postgres databases | **15 min** | Asynchronous streaming replication; WAL shipping to standby |
| Prometheus metrics | **1 hour** | Metrics are observability; loss is acceptable vs. operational data |
| Grafana dashboards | **0 min** | Dashboards stored as code in this repo |

---

## Recovery Time Breakdown (Tier 1, 5-minute RTO)

| Step | Time Budget | Action |
|------|-------------|--------|
| Alert fires + on-call receives page | 0:00 – 0:30 | PagerDuty with 30s escalation |
| Automated health check confirms failure | 0:00 – 1:00 | `health-check-all.sh` runs every 60s |
| Automatic or manual failover initiated | 1:00 – 2:30 | `failover.sh` switches kubectl context and applies manifests |
| DNS TTL propagates | 2:30 – 3:30 | Route53 TTL = 60s |
| Service health checks pass in DR cluster | 3:30 – 4:30 | K8s readiness probes |
| On-call confirms operational | 4:30 – 5:00 | Manual verification via `health-check-all.sh` |

---

## Backup Schedule

| Backup Type | Frequency | Retention | Storage |
|-------------|-----------|-----------|---------|
| Full K8s ConfigMap/Secret backup | Every 15 min | 7 days | S3 `s3://aeromed-backups/k8s/` |
| Postgres full dump | Daily at 02:00 UTC | 30 days | S3 `s3://aeromed-backups/postgres/` |
| Postgres WAL/incremental | Continuous | 7 days | S3 `s3://aeromed-backups/postgres/wal/` |
| Grafana dashboard export | On every deploy | Indefinite | Git repository |

---

## DR Test Results Log

| Date | Test Type | RTO Achieved | RPO Verified | Pass/Fail | Notes |
|------|-----------|-------------|--------------|-----------|-------|
| _(populate after first DR drill)_ | | | | | |

---

## SLA Commitments

| Metric | Target | Measurement Window |
|--------|--------|--------------------|
| Platform availability | 99.9% | Rolling 30 days |
| P1 incident response | < 5 min | Per incident |
| P2 incident response | < 15 min | Per incident |
| Backup success rate | 100% | Weekly audit |
