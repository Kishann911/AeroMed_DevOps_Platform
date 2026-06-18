# AeroMed Platform — DR Testing Guide

## Purpose

This guide documents how to run Disaster Recovery drills for the AeroMed platform. DR tests must be run regularly — failures caught in drills cost minutes; failures caught in production cost patient outcomes.

**DR Test Schedule:**
- Monthly: Tier 3 services health check + failover drill
- Quarterly: Tier 1 full failover drill (scheduled maintenance window)
- Annually: Complete cluster rebuild from Terraform + backup restore

---

## Quick-Start: Demo Simulation Scripts

All scripts are in `scripts/` and can be run without Kubernetes (Docker Compose mode).

```bash
# Make all scripts executable (one-time)
chmod +x scripts/*.sh

# Run the full demo (7 steps, pauses between each for narration)
./scripts/demo-full-recovery.sh

# Individual simulations:
./scripts/simulate-aircraft-comms-failure.sh     # P1 scenario
./scripts/simulate-service-outage.sh             # Generic service outage
./scripts/simulate-service-outage.sh patient-records 30
./scripts/simulate-traffic-surge.sh 60 1000 50  # 1000 req, 50 concurrent, 60s
./scripts/simulate-pod-failure.sh                # Random pod kill + self-healing
./scripts/simulate-node-pressure.sh 30 cpu       # CPU pressure for 30s

# Load test
python3 scripts/load-test.py --duration 60 --workers 20 --ramp 5
```

---

## DR Test Scenarios

### Test 1: Single Service Failure (Tier 1 — P1)

**Objective:** Verify RTO < 5 minutes for Tier 1 services and alert routing works.

**Steps:**

```bash
# 1. Baseline check
./scripts/status.sh

# 2. Inject failure into aircraft-comms
./scripts/simulate-aircraft-comms-failure.sh

# 3. During the simulation, open:
#    - Grafana: http://localhost:3000/d/aeromed-operations-overview
#    - AlertManager: http://localhost:9093
#    - Prometheus: http://localhost:9090/alerts
```

**Pass criteria:**
- [ ] `AircraftCommunicationLost` alert fires within 60s
- [ ] Other 5 services remain healthy throughout (service isolation)
- [ ] Service recovers within 300s (5-minute RTO)
- [ ] Alert auto-resolves after recovery
- [ ] Script prints `RTO TARGET MET`

---

### Test 2: Traffic Surge + HPA Scaling

**Objective:** Verify HPA scales pods under load and system remains responsive.

**Requirements:** Kubernetes with metrics-server (`minikube addons enable metrics-server`)

```bash
# 1. Note baseline replica counts
kubectl get hpa -n aeromed-production

# 2. Run load test (Kubernetes mode)
./scripts/simulate-traffic-surge.sh 120 2000 100

# 3. While running, in another terminal:
kubectl get hpa -n aeromed-production -w
```

**Pass criteria:**
- [ ] emergency-dispatch HPA scales from 2 to >2 replicas within 60s
- [ ] Error rate stays < 5% during surge
- [ ] p95 response time stays < 2s during surge
- [ ] After load stops, pods scale back down within 5 minutes

---

### Test 3: Pod Self-Healing

**Objective:** Verify Kubernetes restarts a killed pod within 30 seconds.

```bash
# Kill a random running pod
./scripts/simulate-pod-failure.sh

# Optionally target a specific service
./scripts/simulate-pod-failure.sh emergency-dispatch
```

**Pass criteria:**
- [ ] Killed pod is replaced by Kubernetes within 30s
- [ ] Service health endpoint returns 200 throughout (other replicas absorb traffic)
- [ ] Script prints pod recovery time < 30s

---

### Test 4: Node Resource Pressure

**Objective:** Verify AeroMed services remain healthy under CPU/memory pressure.

```bash
# CPU pressure for 30 seconds
./scripts/simulate-node-pressure.sh 30 cpu

# Memory pressure for 30 seconds
./scripts/simulate-node-pressure.sh 30 memory

# Both simultaneously
./scripts/simulate-node-pressure.sh 45 both
```

**Pass criteria:**
- [ ] All 6 service health endpoints continue returning 200 during pressure
- [ ] No unexpected pod evictions
- [ ] Resource pressure confined to the stress container (isolation)

---

### Test 5: Full Recovery Drill (Quarterly)

**Objective:** Run the complete end-to-end scenario as a presenter would for a panel.

```bash
# Complete 7-step demo (press Enter to advance each step)
./scripts/demo-full-recovery.sh
```

**Scenarios covered:**
1. Baseline health (all green)
2. Aircraft-comms failure (P1 incident)
3. Degraded state observation (service isolation confirmed)
4. Recovery (RTO measured and displayed)
5. Traffic surge + autoscaling
6. Prometheus alert lifecycle (fire → resolve)
7. Final health + DR summary report

**Pass criteria:**
- [ ] All 7 steps complete without script errors
- [ ] RTO achieved < 300s
- [ ] Final state: all 6 services healthy
- [ ] DR summary report printed with all metrics

---

### Test 6: Backup and Restore Verification (Monthly)

**Objective:** Verify backup process creates valid archives and restore script runs cleanly.

```bash
# Run backup (dry-run first)
./disaster-recovery/scripts/backup.sh

# Verify the backup archive was created
ls -lh /tmp/aeromed-backup-*.tar.gz 2>/dev/null || echo "Check S3 for backup"

# Test restore in dry-run mode (no changes applied)
./disaster-recovery/scripts/restore.sh \
  --timestamp $(date +"%Y%m%d_%H%M") \
  --dry-run
```

**Pass criteria:**
- [ ] Backup script completes without error
- [ ] Archive contains all expected files (ConfigMaps, Secrets, Postgres dump)
- [ ] Restore dry-run shows correct files would be applied
- [ ] S3 upload command logged correctly

---

### Test 7: Cluster Failover (Quarterly, requires two clusters)

**Objective:** Verify `failover.sh` switches traffic to DR cluster within 5 minutes.

**Prerequisites:**
```bash
export AEROMED_PRIMARY_CONTEXT=aeromed-production
export AEROMED_DR_CONTEXT=aeromed-dr
```

```bash
# Step 1: Simulate primary cluster failure (just switch context away to test)
kubectl config use-context aeromed-production
kubectl get nodes  # Should be healthy

# Step 2: Run failover
./disaster-recovery/scripts/failover.sh dr

# Step 3: Verify DR cluster is serving traffic
./disaster-recovery/scripts/health-check-all.sh

# Step 4: Failback to primary
./disaster-recovery/scripts/failover.sh primary
```

**Pass criteria:**
- [ ] Failover script completes in < 180s (kubectl manifests applied)
- [ ] DNS update logged (production: verify Route53 record changed)
- [ ] Health checks pass against DR cluster
- [ ] Failback completes cleanly

---

## Running the Load Test

The Python load test (`scripts/load-test.py`) sends concurrent requests to all 6 services and reports performance metrics.

```bash
# Default: 60s, 20 workers
python3 scripts/load-test.py

# Extended load test: 300s, 50 concurrent workers
python3 scripts/load-test.py --duration 300 --workers 50 --ramp 10

# Target a single URL
python3 scripts/load-test.py --url http://localhost:5004/api/status --duration 30 --workers 30
```

**Sample output:**
```
  AeroMed Load Test Starting
  Duration: 60s | Workers: 20 | Ramp: 5s
  Targets:  6 services

  Pre-flight check...
  ✓  api-gateway               12ms
  ✓  flight-operations         8ms
  ✓  patient-records           11ms
  ✓  medical-equipment         9ms
  ✓  emergency-dispatch        7ms
  ✓  aircraft-comms            8ms

  [████████████████████████████████████████] Done (60.1s)

  ──────────────────────────────────────────────────────────────────────
  │ Service                     │ Req/s  │ Avg (ms) │ p95 (ms) │ Error % │
  ──────────────────────────────────────────────────────────────────────
  │ api-gateway                 │ 28.4   │ 12.1     │ 31.2     │ 0.0%   │
  │ flight-operations           │ 27.9   │ 8.4      │ 19.8     │ 0.0%   │
  │ patient-records             │ 28.1   │ 11.2     │ 28.4     │ 0.0%   │
  │ medical-equipment           │ 28.3   │ 9.1      │ 22.1     │ 0.0%   │
  │ emergency-dispatch          │ 28.7   │ 7.8      │ 18.3     │ 0.0%   │
  │ aircraft-comms              │ 28.5   │ 8.3      │ 20.1     │ 0.0%   │
  ──────────────────────────────────────────────────────────────────────

  RESULT: PASS — platform handled load with <0.1% errors
```

---

## DR Test Results Template

After each DR test, record results in this format:

```markdown
## DR Test — [Date] — [Scenario]

**Tester:** [Name]
**Environment:** [Docker Compose / Minikube / EKS Production]
**Duration:** [minutes]

### Results

| Metric | Target | Actual | Pass/Fail |
|--------|--------|--------|-----------|
| RTO (Tier 1) | < 300s | Xs | PASS/FAIL |
| Alert fired | < 60s | Xs | PASS/FAIL |
| Service isolation | 5/6 healthy | N/6 | PASS/FAIL |
| Error rate during outage | < 10% | X% | PASS/FAIL |
| Final health | 6/6 | N/6 | PASS/FAIL |

### Issues Found
- [List any problems]

### Action Items
- [List improvements required]
```

---

## Interpreting Results

| Result | Meaning | Action |
|--------|---------|--------|
| `RTO TARGET MET` | Recovery < 5 minutes | Document; no action needed |
| `RTO TARGET MISSED` | Recovery > 5 minutes | Root cause + improve deployment speed or add replicas |
| Error rate > 5% | Traffic not absorbed by healthy replicas | Check HPA config + replica baseline |
| `AircraftCommunicationLost` didn't fire | Prometheus alert not configured | Check `alert-rules.yml` + Prometheus targets |
| Health check fails post-recovery | Service recovering but not ready | Check readiness probe config |
