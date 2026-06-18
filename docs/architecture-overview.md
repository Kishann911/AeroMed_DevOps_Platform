# AeroMed Platform — Architecture Overview

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      AeroMed Cloud Infrastructure                           │
│                     (AWS Multi-AZ / Kubernetes EKS)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Internet ──► Route53 ──► ALB (Multi-AZ) ──► Nginx Ingress Controller     │
│                                                          │                  │
│                                             ┌────────────┘                  │
│                                             ▼                               │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │               aeromed-production namespace                          │   │
│   │                                                                     │   │
│   │   ┌─────────────────┐     All requests enter through api-gateway    │   │
│   │   │  api-gateway    │◄──── JWT auth, rate limiting, routing         │   │
│   │   │  (Port 5000)    │                                               │   │
│   │   │  replicas: 2    │                                               │   │
│   │   └────────┬────────┘                                               │   │
│   │            │  internal service mesh (ClusterIP)                     │   │
│   │    ┌───────┼────────────────────────────────┐                       │   │
│   │    ▼       ▼            ▼         ▼         ▼                       │   │
│   │  ┌──────┐ ┌──────────┐ ┌───────┐ ┌───────┐ ┌──────────┐           │   │
│   │  │Flight│ │Patient   │ │Med    │ │Emerg. │ │Aircraft  │           │   │
│   │  │Ops   │ │Records   │ │Equip  │ │Disptch│ │Comms     │           │   │
│   │  │:5001 │ │:5002     │ │:5003  │ │:5004  │ │:5005     │           │   │
│   │  │x2    │ │x2  (PHI) │ │x2     │ │x2     │ │x2        │           │   │
│   │  └──────┘ └──────────┘ └───────┘ └───────┘ └──────────┘           │   │
│   │      ↕           ↕          ↕         ↕          ↕                 │   │
│   │           HPA: 2–10 replicas per service                           │   │
│   │           (scales on CPU >70% or custom metrics)                   │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              ▼                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │               aeromed-monitoring namespace                          │   │
│   │                                                                     │   │
│   │   Prometheus (:9090) ──scrape──► all services /metrics              │   │
│   │        │                                                            │   │
│   │        ├──► AlertManager (:9093) ──► Slack / Email                 │   │
│   │        │                                                            │   │
│   │        └──► Grafana (:3000)                                         │   │
│   │                 ├── aeromed-operations-overview                     │   │
│   │                 ├── aeromed-service-health                          │   │
│   │                 └── aeromed-infrastructure                          │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              ▼                                              │
│   RDS PostgreSQL (Multi-AZ)  +  S3 Backups (15-min RPO)                    │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  DR: aeromed-eu-west-1 (warm standby — activates in < 5 min)       │   │
│   │      ArgoCD syncs K8s manifests | Postgres streaming replication    │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Service Map

| Service | Port | Criticality | Replicas | HPA Range | Responsibility |
|---------|------|-------------|----------|-----------|----------------|
| api-gateway | 5000 | Tier 3 | 2 | 2–8 | JWT auth, routing, rate limiting, failure simulation |
| flight-operations | 5001 | **Tier 1** | 2 | 2–10 | Active flight tracking, position updates, ETA calculation |
| patient-records | 5002 | Tier 2 | 2 | 2–8 | HIPAA-protected PHI, medical history, allergies |
| medical-equipment | 5003 | Tier 2 | 2 | 2–8 | Ventilator/defibrillator telemetry, equipment assignment |
| emergency-dispatch | 5004 | **Tier 1** | 2 | 2–10 | P1/P2 triage, aircraft assignment, queue management |
| aircraft-comms | 5005 | **Tier 1** | 2 | 2–10 | GPS telemetry, crew comms, satellite backup routing |

---

## Architecture Decision Records

### ADR-001: Kubernetes (EKS) for container orchestration

**Decision:** Deploy all services as Kubernetes Deployments on AWS EKS.

**Justification:**
- **Self-healing:** Kubernetes automatically restarts failed pods, maintaining the replica count defined in each Deployment spec. A crashed aircraft-comms pod is replaced without human intervention in ~15–30 seconds.
- **Rolling updates with zero downtime:** `strategy: RollingUpdate` with `maxUnavailable: 0` ensures at least one replica serves traffic during any deployment — critical for a 24/7 air ambulance operation.
- **Horizontal Pod Autoscaler (HPA):** Emergency events cause unpredictable traffic spikes. HPA scales pods within seconds based on CPU/memory metrics without pre-provisioned capacity.
- **Namespace isolation:** `aeromed-production` and `aeromed-monitoring` namespaces with NetworkPolicy prevent a monitoring failure from impacting patient-facing services.

**Trade-off:** Kubernetes adds operational complexity. Mitigated by using managed EKS (no control-plane management) and GitOps via ArgoCD.

---

### ADR-002: Terraform for Infrastructure as Code

**Decision:** All cloud resources defined in Terraform modules under `terraform/`.

**Justification:**
- **Reproducibility:** The DR cluster in `us-west-2` is created by running the same Terraform with a different region variable — identical configuration, zero manual steps.
- **Version control:** Infrastructure changes go through the same code review process as application changes. A bad EKS node group config triggers a PR review before reaching production.
- **State management:** Remote state in S3 + DynamoDB locking prevents concurrent Terraform runs from corrupting infrastructure state.
- **Disaster recovery speed:** Spinning up the DR cluster from scratch takes ~15 minutes via `terraform apply`. The warm-standby approach (cluster always running) reduces this to seconds.

**Trade-off:** Terraform state drift requires care. Mitigated by `terraform plan` in CI before every `apply`.

---

### ADR-003: Prometheus + Grafana for observability

**Decision:** Prometheus time-series metrics with Grafana dashboards and AlertManager routing.

**Justification:**
- **Kubernetes-native:** Prometheus's service discovery automatically finds new pods without configuration changes. As HPA scales emergency-dispatch from 2 to 10 pods, all new pods are scraped automatically.
- **Custom business metrics:** Standard APM tools cannot track `aeromed_emergency_dispatch_active_count` or `aeromed_flights_active_count`. Prometheus allows any Flask metric exposed via `/metrics` to become an alert condition.
- **Open source / no vendor lock-in:** Running Prometheus inside the cluster means metrics are available even during external network outages — critical when the primary failure mode for an air ambulance is connectivity loss.
- **AlertManager routing:** Different alert severity levels route to different teams (flight ops, medical, devops) with different urgency and escalation paths.

**Trade-off:** Prometheus's pull model requires network access to all scraped targets. Mitigated by running Prometheus inside the cluster with ClusterIP access to all services.

---

### ADR-004: Multi-AZ deployment

**Decision:** EKS node groups span at least two Availability Zones (AZ).

**Justification:**
- **Single AZ failure tolerance:** AWS AZ outages occur ~2–4 times per year per region. An air ambulance in transit during an AZ outage cannot wait for single-AZ recovery. With pods spread across AZs, an AZ failure removes at most 50% of capacity; HPA scales remaining pods to compensate.
- **RDS Multi-AZ:** The Postgres primary is synchronously replicated to a standby in a second AZ. Failover is automatic and takes ~60 seconds — within the 300-second Tier 1 RTO.
- **ALB cross-AZ load balancing:** The Application Load Balancer distributes traffic across healthy AZs, automatically stopping traffic to an unhealthy AZ without DNS changes.

**Trade-off:** Cross-AZ data transfer costs ~$0.01/GB. For the traffic volumes involved, this is negligible compared to the cost of a single patient-transport incident caused by a preventable outage.

---

### ADR-005: RollingUpdate with maxUnavailable=0

**Decision:** All Deployments use `strategy.rollingUpdate.maxUnavailable: 0` and `maxSurge: 1`.

**Justification:**
- **Zero downtime deployments:** With `maxUnavailable: 0`, Kubernetes always maintains the full requested replica count during rollout. The new pod must pass readiness probes before the old pod is terminated.
- **Healthcare compliance:** Patient-facing systems must not have planned maintenance windows. With this strategy, a deployment of patient-records can happen at 3am during an active flight without any service interruption.
- **Safe rollback:** If a new version fails its readiness probe, the rollout pauses with the old version still serving 100% of traffic. `kubectl rollout undo` is a one-command recovery.

**Trade-off:** Requires `maxSurge: 1`, so during rollout there is briefly one extra pod running. This costs slightly more in compute resources for ~2–3 minutes per deployment.

---

### ADR-006: HPA for elastic scaling

**Decision:** Each Tier 1 service has an HPA targeting 70% CPU utilisation with a maximum of 10 replicas.

**Justification:**
- **Unpredictable emergency surges:** A mass-casualty event (highway accident, building collapse) can generate 10–50x the normal emergency dispatch volume within 60 seconds. Static replica counts would either waste resources at baseline or fail under surge.
- **Cost efficiency:** Baseline is 2 replicas per service (12 pods total). Under surge, HPA adds capacity within 30–60 seconds. After the event, HPA scales back down within 5 minutes, eliminating idle compute costs.
- **Tier 1 priority:** Emergency-dispatch and aircraft-comms have higher max replicas (10) and lower CPU thresholds (60%) to scale proactively — a 500ms dispatch delay means a delayed aircraft, which means a delayed patient.

**Trade-off:** HPA reacts to CPU pressure, not queue depth. For emergency-dispatch, a custom metric (`aeromed_dispatch_queue_depth`) is also used to enable predictive scaling before CPU saturates.

---

## Data Flow: Emergency Dispatch Request

```
Patient call received
        │
        ▼
ALB → Ingress → api-gateway (:5000)
        │  [auth: JWT validation]
        │  [rate-limit: 100 req/s per IP]
        ▼
emergency-dispatch (:5004)
        │  [triage: P1/P2 classification]
        │  [query: aircraft-comms for available aircraft positions]
        │  [query: patient-records for patient history]
        │  [query: medical-equipment for available equipment]
        ▼
aircraft-comms (:5005)
        │  [assign: nearest aircraft with required equipment]
        │  [notify: crew via satellite link]
        ▼
flight-operations (:5001)
        │  [track: flight activated, position logging begins]
        │  [ETA: calculated from GPS + weather]
        ▼
Response: dispatch ID, aircraft tail number, ETA
```

---

## Network Security

```
NetworkPolicy: aircraft-comms
  Ingress:
    - from emergency-dispatch (port 5005)
    - from flight-operations  (port 5005)
    - from Prometheus         (port /metrics)
  Egress:
    - to satellite telemetry endpoints (HTTPS :443)
    - to DNS (UDP :53)

NetworkPolicy: patient-records
  Ingress:
    - from emergency-dispatch ONLY (HIPAA: minimum necessary access)
    - from Prometheus
  Egress:
    - to aeromed-postgres (TCP :5432)
    - to DNS
```

All inter-service communication is over plaintext within the cluster (mTLS via service mesh optional future enhancement). External traffic terminates TLS at the ALB.
