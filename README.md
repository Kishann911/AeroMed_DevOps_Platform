# AeroMed DevOps Platform
### Mission-Critical Air Ambulance Operations Infrastructure

![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=flat&logo=terraform&logoColor=white)
![Jenkins](https://img.shields.io/badge/Jenkins-D24939?style=flat&logo=jenkins&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat&logo=prometheus&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)

---

## Quick Start (Local Demo)

```bash
# Prerequisites: Docker Desktop (running)
git clone <repo-url> AeroMed_DevOps_Platform
cd AeroMed_DevOps_Platform
chmod +x scripts/*.sh

./scripts/start.sh        # Build + start all 10 services (~2 minutes)
./scripts/status.sh       # Verify all services healthy
```

**For Kubernetes demo (requires Minikube):**
```bash
minikube start --cpus=4 --memory=8192 --addons=ingress,metrics-server
kubectl apply -f kubernetes/ -n aeromed-production --recursive
```

See [docs/deployment-guide.md](docs/deployment-guide.md) for full setup instructions.

---

## Platform Overview

AeroMed is a DevOps platform built for a Critical Care Air Ambulance (HEMS) operation. The platform orchestrates six mission-critical microservices that coordinate patient transport by air: from the moment an emergency call is received through aircraft dispatch, in-flight patient monitoring, and hospital handover. Every component is designed for the assumption that downtime costs patient outcomes — not just SLA points.

The infrastructure demonstrates production-grade DevOps practices across the full stack: containerised microservices built with Docker, orchestrated on Kubernetes with auto-scaling and self-healing, provisioned reproducibly with Terraform, deployed continuously through a Jenkins CI/CD pipeline, and observed through a Prometheus + Grafana monitoring stack with AlertManager routing to differentiated on-call teams. Disaster Recovery procedures are codified in executable runbooks with sub-5-minute RTOs for Tier 1 services.

The platform is deliberately sized for a review panel: the full stack runs on a laptop with Docker Compose, scripts automate failure injection and recovery demonstration, and the Grafana dashboards show real-time platform health that changes visibly when failures are simulated.

---

## Architecture

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
│   │   └────────┬────────┘                                               │   │
│   │            │ internal service mesh (ClusterIP)                      │   │
│   │    ┌───────┼────────────────────────────────┐                       │   │
│   │    ▼       ▼            ▼         ▼         ▼                       │   │
│   │  ┌──────┐ ┌──────────┐ ┌───────┐ ┌───────┐ ┌──────────┐           │   │
│   │  │Flight│ │Patient   │ │Med    │ │Emerg. │ │Aircraft  │           │   │
│   │  │Ops   │ │Records   │ │Equip  │ │Dsptch │ │Comms     │           │   │
│   │  │:5001 │ │:5002(PHI)│ │:5003  │ │:5004  │ │:5005     │           │   │
│   │  │ ×2   │ │ ×2       │ │ ×2    │ │ ×2    │ │ ×2       │           │   │
│   │  └──────┘ └──────────┘ └───────┘ └───────┘ └──────────┘           │   │
│   │                ↕ HPA: 2–10 replicas per service ↕                  │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  Prometheus(:9090) → AlertManager(:9093) → Slack / Email            │   │
│   │  Grafana(:3000): operations-overview · service-health · infra       │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│   RDS PostgreSQL (Multi-AZ) + S3 Backups (15-min RPO)                      │
│   DR: aeromed-eu-west-1 warm standby — RTO < 5 min for Tier 1              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Technology Stack

| Tool | Version | Purpose | Justification |
|------|---------|---------|---------------|
| **Docker** | 24.x | Service containerisation | Reproducible environments; identical behaviour local → production |
| **Kubernetes (EKS)** | 1.28 | Orchestration | Self-healing, rolling deploys, HPA autoscaling |
| **Terraform** | 1.6 | Infrastructure as Code | Reproducible infra; identical primary and DR clusters |
| **Jenkins** | 2.4xx | CI/CD pipeline | Build → test → security scan → deploy in one Jenkinsfile |
| **Prometheus** | 2.47 | Metrics + alerting | Kubernetes-native; custom business metrics per service |
| **Grafana** | 10.x | Dashboards | Multi-panel operational and infrastructure visibility |
| **AlertManager** | 0.26 | Alert routing | Team-differentiated routing (flight ops vs medical vs devops) |
| **Python 3 (Flask)** | 3.12 | Microservices | Lightweight, fast iteration, Prometheus client built-in |
| **Nginx Ingress** | 1.9 | Edge routing | Path-based routing to all services behind single ALB |
| **AWS ALB** | — | Load balancing | Multi-AZ, native health checks, TLS termination |

---

## Services

| Service | Port | Responsibility | Criticality | HPA Range |
|---------|------|----------------|-------------|-----------|
| api-gateway | 5000 | JWT auth, routing, rate limiting, failure simulation API | Tier 3 | 2–8 |
| flight-operations | 5001 | Active flight tracking, position updates, ETA calculation | **Tier 1 P1** | 2–10 |
| patient-records | 5002 | HIPAA-protected PHI, medical history, allergies, allergies | Tier 2 P2 | 2–8 |
| medical-equipment | 5003 | Ventilator/defibrillator telemetry, equipment assignment | Tier 2 P2 | 2–8 |
| emergency-dispatch | 5004 | P1/P2 triage, aircraft assignment, queue management | **Tier 1 P1** | 2–10 |
| aircraft-comms | 5005 | GPS telemetry, crew communication, satellite backup routing | **Tier 1 P1** | 2–10 |

---

## Running the Demo

### Step 1 — Start and verify the platform

```bash
./scripts/start.sh
./scripts/status.sh
# All 6 services should show HEALTHY
```

### Step 2 — Open Grafana

- URL: **http://localhost:3000** (admin / aeromed123)
- Dashboard: **AeroMed Operations Overview**
- You should see: Platform Health = 6, zero active alerts

### Step 3 — Run the full resilience demo

```bash
./scripts/demo-full-recovery.sh
```

This runs a 7-step scripted scenario with pause-to-narrate between each step:
1. Show all services healthy (baseline)
2. Simulate aircraft-comms failure (P1 incident)
3. Show degraded state — 5/6 services still healthy (service isolation)
4. Show automatic recovery — RTO measured and printed
5. Traffic surge — HPA scales under load
6. Prometheus alert lifecycle (firing → resolving)
7. Final health verification + DR summary report

### Step 4 — Individual simulation scripts

```bash
./scripts/simulate-aircraft-comms-failure.sh     # P1 aircraft comms down
./scripts/simulate-service-outage.sh flight-operations 30
./scripts/simulate-traffic-surge.sh 60 1000 50  # 1000 req, 50 concurrent, 60s
./scripts/simulate-pod-failure.sh                # Self-healing demo
./scripts/simulate-node-pressure.sh 30 cpu       # Resource pressure
python3 scripts/load-test.py --duration 60 --workers 20
```

### Step 5 — Jenkins pipeline

- URL: **http://localhost:8080** (admin / aeromed123)
- Create a pipeline job using `jenkins/Jenkinsfile`
- Stages: Build → Test → Security Scan → Deploy Staging → Integration Tests → Deploy Production

---

## Key API Endpoints

```
GET  http://localhost:5000/api/all-status              # Aggregated status of all 6 services
GET  http://localhost:5000/api/status                  # Gateway status
POST http://localhost:5000/simulate/failure            # Inject a failure
     Body: {"service": "aircraft-comms", "duration_seconds": 30}
POST http://localhost:5000/simulate/clear              # Clear injected failure
     Body: {"service": "aircraft-comms"}

GET  http://localhost:<port>/health                    # Per-service health check
GET  http://localhost:<port>/metrics                   # Prometheus metrics endpoint
GET  http://localhost:<port>/api/status                # Service domain data
```

---

## Disaster Recovery

| Tier | Services | RTO Target |
|------|----------|-----------|
| 1 | flight-ops, emergency-dispatch, aircraft-comms | **< 5 minutes** |
| 2 | patient-records, medical-equipment | < 15 minutes |
| 3 | api-gateway, monitoring | < 30 minutes |

| Runbook | Scenario |
|---------|---------|
| [RB-001](disaster-recovery/runbooks/RB-001-service-failure.md) | Service pod failure |
| [RB-002](disaster-recovery/runbooks/RB-002-pod-crashloop.md) | CrashLoopBackOff |
| [RB-003](disaster-recovery/runbooks/RB-003-aircraft-comms-loss.md) | Aircraft communication loss (P1) |
| [RB-004](disaster-recovery/runbooks/RB-004-database-failure.md) | Database failure |
| [RB-005](disaster-recovery/runbooks/RB-005-full-cluster-failure.md) | Full cluster failure |
| [RB-006](disaster-recovery/runbooks/RB-006-traffic-surge.md) | Mass casualty traffic surge |

DR scripts: `disaster-recovery/scripts/` — backup, restore, failover, health-check-all.

---

## Monitoring

| Dashboard | URL | Purpose |
|-----------|-----|---------|
| Operations Overview | http://localhost:3000/d/aeromed-operations-overview | Primary on-call view |
| Service Deep Dive | http://localhost:3000/d/aeromed-service-health | Per-service latency/error deep dive |
| Infrastructure | http://localhost:3000/d/aeromed-infrastructure | Node CPU, memory, HPA, replicas |
| Prometheus | http://localhost:9090 | Raw metrics, alert rules, targets |
| AlertManager | http://localhost:9093 | Alert routing, silences, inhibit rules |

---

## Project Structure

```
AeroMed_DevOps_Platform/
├── services/                          # Six Flask microservices
│   ├── api-gateway/                   #   Port 5000 — routing + failure simulation
│   ├── flight-operations/             #   Port 5001 — Tier 1 P1
│   ├── patient-records/               #   Port 5002 — HIPAA PHI
│   ├── medical-equipment/             #   Port 5003
│   ├── emergency-dispatch/            #   Port 5004 — Tier 1 P1
│   └── aircraft-comms/               #   Port 5005 — Tier 1 P1
│
├── kubernetes/                        # K8s manifests
│   ├── namespaces/                    #   aeromed-production + monitoring
│   ├── deployments/                   #   RollingUpdate, maxUnavailable=0
│   ├── services/                      #   ClusterIP + LoadBalancer
│   ├── hpa/                           #   2–10 replicas, CPU 70% target
│   ├── ingress/                       #   Nginx path-based routing
│   ├── network-policies/              #   HIPAA-compliant isolation
│   ├── configmaps/                    #   Environment configuration
│   ├── secrets/                       #   Credentials (base64)
│   └── rbac/                          #   Least-privilege service accounts
│
├── terraform/                         # Infrastructure as Code
│   └── modules/                       #   EKS, RDS, ALB, S3, IAM
│
├── jenkins/                           # CI/CD
│   ├── Jenkinsfile                    #   Build→Test→Scan→Deploy pipeline
│   └── shared-library/               #   Reusable pipeline functions
│
├── monitoring/
│   ├── prometheus/                    #   Scrape config + alert rules
│   ├── grafana/
│   │   ├── datasources/               #   Prometheus + AlertManager datasources
│   │   └── dashboards/               #   3 JSON dashboards + provisioning config
│   └── alertmanager/
│       ├── alertmanager.yml           #   5 receivers, route tree, inhibit rules
│       └── notification-templates.tmpl#  Branded Slack + email templates
│
├── disaster-recovery/
│   ├── README.md                      #   DR strategy, tiers, escalation paths
│   ├── rto-rpo.md                     #   Recovery objectives + SLAs
│   ├── runbooks/                      #   RB-001 through RB-006
│   └── scripts/
│       ├── backup.sh                  #   K8s configs + Postgres → S3
│       ├── restore.sh                 #   Restore from timestamped backup
│       ├── failover.sh                #   Primary → DR cluster switch
│       └── health-check-all.sh       #   Coloured status table + exit code
│
├── scripts/
│   ├── start.sh                       #   Docker Compose startup
│   ├── stop.sh                        #   Graceful shutdown
│   ├── status.sh                      #   Health status table
│   ├── demo-full-recovery.sh          #   7-step presenter demo script
│   ├── simulate-aircraft-comms-failure.sh  # P1 aircraft comms scenario
│   ├── simulate-service-outage.sh     #   Generic service outage
│   ├── simulate-traffic-surge.sh      #   Load surge + HPA scaling
│   ├── simulate-pod-failure.sh        #   Self-healing demonstration
│   ├── simulate-node-pressure.sh      #   CPU/memory pressure
│   └── load-test.py                   #   Concurrent load tester with table output
│
├── docs/
│   ├── architecture-overview.md       #   ASCII diagram + 6 ADRs
│   ├── deployment-guide.md            #   Docker / Minikube / EKS instructions
│   ├── monitoring-guide.md            #   Grafana, Prometheus, alerts reference
│   └── dr-testing-guide.md           #   DR drill procedures + pass criteria
│
└── docker-compose.yml                 # Full local stack definition
```

---

## Documentation

| Document | Contents |
|----------|---------|
| [Architecture Overview](docs/architecture-overview.md) | ASCII architecture diagram, service map, 6 Architecture Decision Records |
| [Deployment Guide](docs/deployment-guide.md) | Docker Compose, Minikube, EKS, Jenkins setup, common issues |
| [Monitoring Guide](docs/monitoring-guide.md) | Grafana dashboards, Prometheus queries, alert reference, SLO definitions |
| [DR Testing Guide](docs/dr-testing-guide.md) | 7 DR test scenarios, pass/fail criteria, load test, results template |
| [DR README](disaster-recovery/README.md) | DR strategy, recovery tiers, runbook index, test schedule |
| [RTO/RPO](disaster-recovery/rto-rpo.md) | Recovery objectives, backup schedule, SLA commitments |
