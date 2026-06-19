# AeroMed DevOps Platform — Viva Presentation Script
### Case Study 75: Critical Care Air Ambulance Operations Platform
**Target length:** ~10 minutes spoken (~1,500–1,900 words). Timing markers are cumulative.
**Presenter note:** Bracketed *[DEMO: …]* lines are actions to take on screen, not words to read.

---

## 0:00 — Opening & Problem Framing  *(~45 sec)*

"Good morning. I'm presenting **Project AeroMed**, a production-grade DevOps platform for a global air ambulance network.

The defining constraint of this domain is that **infrastructure failure is a patient-safety event**. When an air ambulance is mid-evacuation, a lost service isn't an inconvenience — it can sever flight telemetry or block access to a patient's medical record during critical care. So our entire engineering approach is built around three principles: **high availability, observability, and provable disaster recovery**.

Over the next ten minutes I'll walk through the architecture, the Kubernetes platform, our resilience mechanisms, monitoring, the CI/CD automation, and the infrastructure-as-code — and I'll tie each one back to a real failure scenario a reviewer might simulate."

---

## 0:45 — System Architecture  *(~1 min 15 sec)*

"AeroMed follows a **microservices architecture** with six independently deployable services, each owning a single business capability. This isn't decomposition for its own sake — it gives us **fault isolation**: a failure in one service must never cascade into another.

All external traffic enters through a single **API Gateway**, which is the only internet-facing component. The gateway aggregates health, proxies requests to backend services, and enforces a consistent entry contract. Behind it sit five domain services that never talk to the outside world directly.

The design principles are:
- **Loose coupling** — services communicate over HTTP with explicit timeouts, so a slow dependency degrades gracefully instead of hanging.
- **Stateless services** — every service can be scaled horizontally or rescheduled onto any node, because no state lives in the pod.
- **Observability by default** — every service exposes a `/health` endpoint for liveness and a `/metrics` endpoint in Prometheus format.
- **Separation of concerns** — application code, infrastructure, CI/CD, and monitoring are each version-controlled in their own directory tree.

*[DEMO: show `docker compose ps` or the running stack — all services healthy.]*"

---

## 2:00 — Core Services  *(~1 min 15 sec)*

"Let me walk through the six services.

- The **API Gateway** is the front door. Its key endpoint is `/api/all-status`, which fans out to every backend and returns one aggregated health view — this is what our dashboards and demo rely on. It also exposes a controlled fault-injection endpoint, `/simulate/failure`, which lets us safely demonstrate degradation on demand.
- **Flight Operations** manages flight planning and aircraft mission state — a **Tier 1** service.
- **Emergency Dispatch** coordinates emergency response workflows and the dispatch queue — also **Tier 1**, because an unhandled emergency has direct patient impact.
- **Aircraft Comms** handles communication links, telemetry, and GPS tracking with aircraft in flight — the most safety-critical **Tier 1** service.
- **Patient Records** stores clinical records — **Tier 2**: crews can work short-term from handoff, but it's needed for clinical decisions.
- **Medical Equipment** monitors onboard device telemetry — also **Tier 2**.

Each service is a **Flask application**, containerized with its own Dockerfile, exposing health and Prometheus metrics. The tiering you just heard isn't cosmetic — it directly drives our recovery-time objectives, which I'll come back to."

---

## 3:15 — Kubernetes Infrastructure  *(~1 min 30 sec)*

"In production these services run on **Kubernetes**, and the `kubernetes/` directory holds the full manifest set:

- **Deployments** — each service runs with a **minimum of 2 replicas** across nodes, so a single pod or node loss never causes an outage. Pods carry liveness and readiness probes wired to `/health`, so Kubernetes self-heals automatically — a crashed pod is restarted, a failed readiness check pulls the pod out of the load-balancer rotation.
- **Services** provide stable internal DNS and load-balancing across replicas.
- **ConfigMaps** externalize non-secret configuration, so the same image runs in any environment.
- **Secrets** hold credentials, mounted as environment variables — and I'll be transparent: today this uses native Kubernetes Secrets, with a **documented migration path to HashiCorp Vault** via the Vault Agent Injector, which is the production hardening step.
- **RBAC** enforces least-privilege — service accounts get only the permissions they need.
- **Network Policies** implement a **default-deny** posture: only explicitly allowed service-to-service traffic flows, so a compromised pod can't move laterally.
- **Ingress** terminates TLS and routes external traffic to the gateway.
- **HPA — Horizontal Pod Autoscalers** — scale each service from **2 up to 10 replicas** at **70% CPU utilization**. This is our automated answer to traffic surges.

*[DEMO: `kubectl get deploy,hpa` or show the HPA manifest.]*"

---

## 4:45 — Disaster Recovery  *(~1 min 30 sec)*

"Disaster recovery is where this project goes beyond a normal deployment, because in this domain DR is a first-class deliverable.

We define recovery objectives by **tier**:
- **Tier 1** — flight-operations, emergency-dispatch, aircraft-comms — **5-minute RTO**.
- **Tier 2** — patient-records, medical-equipment — **15-minute RTO**.
- **Tier 3** — gateway and monitoring — **30-minute RTO**.
- Our **RPO** for operational data is tight, while Prometheus metrics tolerate up to an hour of loss because they're observability, not transactional data.

To make recovery **repeatable rather than heroic**, we wrote six numbered runbooks:
- **RB-001** Service Pod Failure, **RB-002** Pod CrashLoopBackOff, **RB-003** Aircraft Communication Loss, **RB-004** Database Failure, **RB-005** Full Cluster Failure, and **RB-006** Traffic Surge / Mass-Casualty Event.

Each runbook is a step-by-step operator procedure. These are backed by automation scripts — `backup.sh`, `restore.sh`, `failover.sh`, and `health-check-all.sh` — so recovery actions are scripted and consistent under pressure.

**Real scenario — aircraft communication loss (RB-003):** if aircraft-comms goes down, the `AircraftCommunicationLost` alert fires immediately, AlertManager routes it to the critical-ops channel, Kubernetes attempts pod recovery, and the operator follows RB-003 to confirm telemetry restoration — all inside the 5-minute Tier-1 window."

---

## 6:15 — Monitoring & Observability  *(~1 min 15 sec)*

"Our monitoring stack is **Prometheus, Grafana, and AlertManager**.

**Prometheus** scrapes the `/metrics` endpoint of every service and evaluates our alert rules. We have two rule families: **application alerts** — like `AircraftCommunicationLost`, `EmergencyDispatchServiceDown`, `HighErrorRate`, `P1EmergencyResponseTimeExceeded`, and `EmergencyQueueBacklog` — and **infrastructure alerts** — like `PodCrashLoopBackOff`, `NodeNotReady`, `NodeMemoryPressure`, and `HPAMaxReplicasReached`. We also use **recording rules** to pre-compute expensive queries for dashboard performance.

**Grafana** provides three dashboards — an **Operations Overview**, **Service Deep-Dive**, and **Infrastructure** view — provisioned automatically from code, pointing at Prometheus as a provisioned datasource. *[DEMO: open Grafana — Platform Health, Request Rate, Error Rate panels.]*

**AlertManager** is the routing brain. Alerts are routed by **team and severity** — aircraft-comms alerts go to critical-ops, medical alerts to the medical team, everything else to DevOps — over Slack and email, using shared notification templates. This means the **right human is paged for the right failure**, which is essential when seconds matter.

On logging: services emit **structured logs to stdout**, collected through the container runtime today, with an **ELK/Loki aggregation layer as the planned centralization step**."

---

## 7:30 — CI/CD Pipelines  *(~1 min)*

"Delivery is automated with **Jenkins**. The `jenkins/` tree has a master `Jenkinsfile`, a dedicated pipeline per service, and — importantly — a **shared pipeline library** with three reusable steps: `aeromedBuild`, `aeromedDeploy`, and `aeromedNotify`.

The shared library is the key engineering decision here: instead of copy-pasting pipeline logic into six services, build, deploy, and notification logic live in **one versioned place**. Each service's pipeline is just a few lines that call these shared steps. That gives us **consistency and a single point of change** — if we harden the deploy process, every service inherits it instantly.

A typical pipeline run: checkout, **build and tag the Docker image**, run tests, push to the registry, **deploy to Kubernetes with a rolling update**, and notify the team of the result. Rolling updates mean **zero-downtime deployments** — old pods stay up until new ones pass readiness checks."

---

## 8:30 — Infrastructure as Code  *(~45 sec)*

"All cloud infrastructure is **Terraform**, so the entire environment is reproducible and peer-reviewable — no click-ops.

The root configuration composes four modules:
- **eks-cluster** — the managed Kubernetes control plane and worker node groups.
- **networking** — VPC, subnets, and security groups, with public/private separation.
- **rds** — the managed, **Multi-AZ** database, which is what gives us automated failover and backups behind RB-004.
- **monitoring** — the supporting observability infrastructure.

Because it's modular, we can stand up an identical staging or DR region by re-applying the same code with different variables. This is the foundation that makes our **Full Cluster Failure runbook, RB-005, credible** — we can rebuild the environment from code."

---

## 9:15 — Testing, Simulation & Live Resilience  *(~45 sec)*

"Finally, resilience you can't demonstrate is just a claim — so we built **simulation tooling**. The `demo-full-recovery.sh` script drives a live resilience walkthrough on the running stack.

**Real scenario — traffic surge (RB-006):** during a mass-casualty event, request volume spikes. Prometheus sees CPU cross 70%, the **HPA scales the affected service from 2 toward 10 replicas automatically**, and the platform absorbs the load without manual action. *[DEMO: trigger the surge / failure-injection step.]*

**Real scenario — database failure (RB-004):** RDS Multi-AZ promotes the standby automatically; the operator follows RB-004 to verify data integrity within the Tier-2 window.

So across comms loss, database failure, and traffic surge, the platform **detects, alerts, recovers, and is verifiable** — automatically wherever possible, and via scripted runbooks where a human decision is required."

---

## 10:00 — Closing  *(~30 sec)*

"To summarize: AeroMed delivers a **resilient, observable, fully automated** cloud-native platform. Six isolated microservices on Kubernetes with autoscaling and self-healing, end-to-end monitoring with team-aware alerting, six tested DR runbooks tied to tiered recovery objectives, Jenkins CI/CD on a shared library, and Terraform infrastructure-as-code.

Every design choice traces back to the one thing that matters in this domain: **keeping mission-critical healthcare transportation running when components fail.** Thank you — I'm happy to take questions or run a live failure-and-recovery demonstration."

---

## Appendix — Likely Examiner Questions & Honest Answers

- **"Where is the ELK stack?"** — "Logging is currently structured stdout collected via the container runtime. Centralized aggregation with ELK/Loki is the documented next increment; the application side is already log-structured for it."
- **"Is Vault actually deployed?"** — "Not yet — we use native Kubernetes Secrets today, with a documented Vault Agent Injector migration path in the secrets manifest. I can speak to the integration design."
- **"Show the architecture diagram."** — Have the architecture + deployment diagrams ready (see gap list); if asked live, narrate the gateway→services→data flow.
- **"How do you prove the 5-minute RTO?"** — Point to the RTO/RPO recovery-time breakdown table and the `demo-full-recovery.sh` measured run.
- **"What happens if the gateway itself dies?"** — "It runs 2+ replicas behind a Service with an HPA; Kubernetes reschedules, and it's Tier-3 with a 30-minute RTO since it carries no patient-safety state itself."
