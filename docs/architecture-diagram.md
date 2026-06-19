# AeroMed DevOps Platform — Architecture & Deployment Diagrams
### Case Study 75: Critical Care Air Ambulance Operations Platform

All diagrams below are written in **Mermaid** and render natively on GitHub, VS Code
(with a Mermaid extension), and most Markdown viewers. They are generated directly from
the actual codebase — ports, replica counts, modules, and service names all match the
implementation.

---

## 1. System Architecture (Logical)

High-level view of the microservices, how requests flow, and how observability and CI/CD
attach to the platform.

```mermaid
flowchart TB
    subgraph CLIENT["External Clients"]
        U["Operations Console /<br/>Dispatch Clients"]
    end

    subgraph EDGE["Edge / Entry"]
        ING["Ingress<br/>(TLS termination)"]
        GW["API Gateway<br/>:5050 → :5000<br/>aggregates · proxies · fault-injection"]
    end

    subgraph CORE["Core Microservices (Flask · stateless · /health + /metrics)"]
        FO["Flight Operations<br/>:5001 · Tier 1"]
        ED["Emergency Dispatch<br/>:5004 · Tier 1"]
        AC["Aircraft Comms<br/>:5005 · Tier 1"]
        PR["Patient Records<br/>:5002 · Tier 2"]
        ME["Medical Equipment<br/>:5003 · Tier 2"]
    end

    subgraph DATA["Data Layer"]
        DB[("RDS<br/>Multi-AZ Database")]
    end

    subgraph OBS["Observability"]
        PROM["Prometheus :9090<br/>scrape /metrics · alert rules"]
        AM["AlertManager :9093<br/>route by team + severity"]
        GRAF["Grafana :3000<br/>3 dashboards"]
    end

    U --> ING --> GW
    GW -->|HTTP + timeouts| FO
    GW -->|HTTP + timeouts| ED
    GW -->|HTTP + timeouts| AC
    GW -->|HTTP + timeouts| PR
    GW -->|HTTP + timeouts| ME

    PR --> DB
    ME --> DB
    ED --> DB

    PROM -.scrape.-> GW
    PROM -.scrape.-> FO
    PROM -.scrape.-> ED
    PROM -.scrape.-> AC
    PROM -.scrape.-> PR
    PROM -.scrape.-> ME
    PROM --> AM
    PROM --> GRAF
    AM -->|Slack / Email| TEAMS["Critical-Ops · Flight-Ops<br/>Medical · DevOps teams"]

    classDef tier1 fill:#7f1d1d,stroke:#fca5a5,color:#fff;
    classDef tier2 fill:#78350f,stroke:#fcd34d,color:#fff;
    classDef edge fill:#1e3a8a,stroke:#93c5fd,color:#fff;
    classDef obs fill:#064e3b,stroke:#6ee7b7,color:#fff;
    class FO,ED,AC tier1;
    class PR,ME tier2;
    class GW,ING edge;
    class PROM,AM,GRAF obs;
```

**Key design points**
- **Single entry point** — only the API Gateway is internet-facing; the five domain services are never exposed directly.
- **Fault isolation** — gateway→service calls use explicit HTTP timeouts, so a slow/down dependency degrades gracefully instead of cascading.
- **Tiering drives DR** — Tier 1 (red) = 5-min RTO, Tier 2 (amber) = 15-min RTO.
- **Observability is pull-based** — Prometheus scrapes every `/metrics` endpoint; nothing in the request path depends on the monitoring stack.

---

## 2. Deployment Architecture (Kubernetes on AWS EKS)

Physical/runtime view: how the services are deployed, scaled, secured, and exposed inside
the cluster, and how the cluster sits on AWS infrastructure provisioned by Terraform.

```mermaid
flowchart TB
    subgraph AWS["AWS (provisioned by Terraform)"]
        subgraph VPC["VPC — networking module"]
            subgraph PUB["Public Subnets"]
                ALB["Ingress / Load Balancer"]
            end
            subgraph PRIV["Private Subnets"]
                subgraph EKS["EKS Cluster — eks-cluster module"]
                    subgraph NS["Namespace: aeromed (RBAC + NetworkPolicy: default-deny)"]
                        direction TB
                        GWD["Deployment: api-gateway<br/>replicas 2 · HPA 2→10 @70% CPU"]
                        SVCS["Deployments ×5 domain services<br/>each replicas 2 · HPA 2→10 @70% CPU<br/>liveness/readiness → /health"]
                        CM["ConfigMap<br/>aeromed-configmap"]
                        SEC["Secret<br/>aeromed-secrets (Opaque)<br/>→ Vault migration path"]
                        SA["ServiceAccounts + RBAC<br/>(least privilege)"]
                    end
                    MON["Monitoring workloads<br/>Prometheus · Grafana · AlertManager"]
                end
            end
            RDS[("RDS Multi-AZ<br/>rds module — auto failover + backups")]
        end
    end

    DEV["Engineer"] -->|git push| GIT["GitHub Repo"]
    GIT --> JEN["Jenkins CI/CD<br/>shared library:<br/>aeromedBuild · aeromedDeploy · aeromedNotify"]
    JEN -->|build + push image| ECR["Container Registry"]
    JEN -->|kubectl rolling update| GWD
    ECR --> GWD
    ECR --> SVCS

    Internet(["Internet"]) --> ALB --> GWD --> SVCS
    SVCS --> RDS
    CM -.injects config.-> SVCS
    SEC -.injects secrets.-> SVCS
    MON -.scrape /metrics.-> GWD
    MON -.scrape /metrics.-> SVCS

    classDef aws fill:#0f3460,stroke:#5b9bd5,color:#fff;
    classDef k8s fill:#16213e,stroke:#6ee7b7,color:#fff;
    classDef cicd fill:#3a1c71,stroke:#c4b5fd,color:#fff;
    class ALB,RDS,VPC,PUB,PRIV aws;
    class GWD,SVCS,CM,SEC,SA,MON k8s;
    class JEN,ECR,GIT cicd;
```

**Resilience features visible here**
- **2-replica minimum** per service across nodes → no single pod/node loss causes an outage.
- **HPA 2→10 @ 70% CPU** → automatic absorption of traffic surges (RB-006).
- **RDS Multi-AZ** → automatic database failover (RB-004).
- **Default-deny NetworkPolicy + RBAC** → lateral-movement and privilege containment.
- **Rolling updates** from Jenkins → zero-downtime deploys.

---

## 3. CI/CD Pipeline Flow

```mermaid
flowchart LR
    A["git push"] --> B["Jenkins<br/>per-service pipeline"]
    B --> C["aeromedBuild<br/>build + tag image"]
    C --> D["Run tests"]
    D --> E["Push to registry"]
    E --> F["aeromedDeploy<br/>kubectl rolling update"]
    F --> G{"Readiness<br/>probes pass?"}
    G -->|yes| H["aeromedNotify<br/>✅ success → team"]
    G -->|no| I["Rollback +<br/>aeromedNotify ❌ failure"]

    classDef step fill:#1e293b,stroke:#94a3b8,color:#fff;
    class A,B,C,D,E,F,H,I step;
```

The three **shared-library steps** (`aeromedBuild`, `aeromedDeploy`, `aeromedNotify`) are
defined once and reused by all six service pipelines — single point of change, consistent
behavior everywhere.

---

## 4. Monitoring & Alert Routing Flow

```mermaid
flowchart TB
    SVCS["6 microservices<br/>/metrics endpoints"] -->|scrape| PROM["Prometheus :9090"]
    PROM -->|evaluate| RULES["Alert rules:<br/>App (AircraftCommunicationLost,<br/>P1EmergencyResponseTimeExceeded, HighErrorRate…)<br/>+ Infra (PodCrashLoopBackOff, NodeNotReady…)"]
    PROM -->|recording rules| GRAF["Grafana :3000<br/>Ops Overview · Service Deep-Dive · Infrastructure"]
    RULES -->|fire| AM["AlertManager :9093<br/>route by alertname/severity"]
    AM --> CRIT["critical-ops<br/>(aircraft-comms)"]
    AM --> FLT["flight-ops team"]
    AM --> MED["medical team<br/>(records/equipment)"]
    AM --> DOPS["devops team<br/>(default)"]

    classDef obs fill:#064e3b,stroke:#6ee7b7,color:#fff;
    class PROM,GRAF,AM,RULES obs;
```

---

## 5. Disaster Recovery Map (Runbooks ↔ Scenarios ↔ RTO)

```mermaid
flowchart LR
    subgraph T1["Tier 1 — RTO 5 min"]
        RB3["RB-003<br/>Aircraft Comms Loss"]
        RB1["RB-001<br/>Service Pod Failure"]
        RB2["RB-002<br/>Pod CrashLoopBackOff"]
    end
    subgraph T2["Tier 2 — RTO 15 min"]
        RB4["RB-004<br/>Database Failure"]
    end
    subgraph T3["Tier 3 — RTO 30 min"]
        RB5["RB-005<br/>Full Cluster Failure"]
        RB6["RB-006<br/>Traffic Surge / Mass Casualty"]
    end

    RB3 --> M3["AircraftCommunicationLost alert<br/>→ K8s self-heal → operator verify"]
    RB4 --> M4["RDS Multi-AZ auto-failover<br/>→ restore.sh / verify integrity"]
    RB5 --> M5["Terraform re-apply<br/>→ rebuild region from code"]
    RB6 --> M6["HPA scales 2→10<br/>→ absorb surge automatically"]

    classDef t1 fill:#7f1d1d,stroke:#fca5a5,color:#fff;
    classDef t2 fill:#78350f,stroke:#fcd34d,color:#fff;
    classDef t3 fill:#1e3a8a,stroke:#93c5fd,color:#fff;
    class RB1,RB2,RB3 t1;
    class RB4 t2;
    class RB5,RB6 t3;
```

---

### How to export these as images (for screenshots / slides)
- **GitHub**: push the repo — diagrams render automatically in the rendered Markdown.
- **VS Code**: install "Markdown Preview Mermaid Support", open preview, screenshot.
- **CLI**: `npx @mermaid-js/mermaid-cli -i docs/architecture-diagram.md -o diagram.png`
- **Online**: paste any block into <https://mermaid.live> and export PNG/SVG.
