# AeroMed Disaster Recovery Plan

## Overview

This document defines the Disaster Recovery (DR) strategy for the AeroMed Critical Care Air Ambulance platform. Given that platform failures can directly impact patient safety and active flight operations, all teams must treat DR procedures as life-critical.

---

## Recovery Objectives

| Objective | Target | Rationale |
|-----------|--------|-----------|
| **RTO** (Recovery Time Objective) | **5 minutes** for Tier 1 services | Active aircraft cannot lose contact for longer |
| **RPO** (Recovery Point Objective) | **15 minutes** | Maximum data loss acceptable before patient record integrity is compromised |

---

## DR Strategy

**Multi-AZ Active-Passive with Automatic Failover**

- Primary cluster runs in `us-east-1` (AZ: `us-east-1a`, `us-east-1b`)
- Warm standby cluster in `us-west-2` receives continuous config replication
- DNS failover via Route53 health checks (60-second TTL)
- Persistent data replicated via asynchronous Postgres streaming replication (lag < 5 minutes)
- Kubernetes manifests stored in Git and auto-synced to standby cluster via ArgoCD

---

## DR Tiers

### Tier 1 — RTO < 5 Minutes (Patient/Flight Safety Critical)

| Service | Port | Impact if Down |
|---------|------|----------------|
| `flight-operations` | 5001 | Active flight tracking lost; aircraft position unknown |
| `emergency-dispatch` | 5004 | New emergency requests cannot be assigned aircraft |
| `aircraft-comms` | 5005 | Real-time telemetry and crew communication severed |

**Action on failure:** Automatic failover to standby cluster + immediate P1 page to on-call.

### Tier 2 — RTO < 15 Minutes (Patient Care Critical)

| Service | Port | Impact if Down |
|---------|------|----------------|
| `patient-records` | 5002 | Medical history unavailable; crews work from verbal handoff |
| `medical-equipment` | 5003 | Equipment telemetry lost; manual monitoring required |

**Action on failure:** Manual failover approval required + P2 page.

### Tier 3 — RTO < 30 Minutes (Operational Support)

| Service | Port | Impact if Down |
|---------|------|----------------|
| `api-gateway` | 5000 | External API access degraded; internal services continue |
| `monitoring` | 9090/3000 | Observability lost; operational impact minimal short-term |

**Action on failure:** Standard incident response; no automatic failover.

---

## Runbooks

| ID | Scenario | Severity |
|----|----------|----------|
| [RB-001](runbooks/RB-001-service-failure.md) | Service pod failure / restart loop | P2 |
| [RB-002](runbooks/RB-002-pod-crashloop.md) | CrashLoopBackOff container | P2 |
| [RB-003](runbooks/RB-003-aircraft-comms-loss.md) | Aircraft communication loss | **P1** |
| [RB-004](runbooks/RB-004-database-failure.md) | Database failure / data loss | P1 |
| [RB-005](runbooks/RB-005-full-cluster-failure.md) | Full cluster failure | **P1** |
| [RB-006](runbooks/RB-006-traffic-surge.md) | Traffic surge / mass casualty event | P1 |

---

## DR Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/backup.sh`](scripts/backup.sh) | Backup K8s configs and persistent data to S3 |
| [`scripts/restore.sh`](scripts/restore.sh) | Restore from a specific backup timestamp |
| [`scripts/failover.sh`](scripts/failover.sh) | Execute cluster failover to DR region |
| [`scripts/health-check-all.sh`](scripts/health-check-all.sh) | Verify all services and monitoring are healthy |

---

## Escalation Path

```
On-call Engineer (PagerDuty)
  → Team Lead (phone: on-call rotation)
    → VP Engineering (if Tier 1 > 10 min unresolved)
      → CEO / Medical Director (if patient safety at risk)
```

---

## DR Test Schedule

- **Monthly:** Health check script + failover drill for Tier 3 services
- **Quarterly:** Full Tier 1 failover drill (scheduled maintenance window)
- **Annually:** Complete cluster DR test including backup/restore validation

See [rto-rpo.md](rto-rpo.md) for detailed recovery time measurements.
