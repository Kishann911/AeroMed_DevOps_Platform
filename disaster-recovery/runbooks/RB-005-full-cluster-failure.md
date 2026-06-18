# RB-005 — Full Cluster Failure

**Severity:** P1 — MAXIMUM PRIORITY
**Last Updated:** 2026-06-16

---

> **ALL-HANDS INCIDENT.** A full cluster failure means all AeroMed services are simultaneously unavailable. All active flights, emergencies, and patient care operations are affected. Activate this runbook alongside the Disaster Recovery failover procedure immediately.

---

## Symptoms

- All pods in `aeromed-production` namespace are `Pending` or `Unknown`
- `kubectl get nodes` shows all nodes `NotReady`
- Grafana "Platform Health" shows 0 healthy services
- AlertManager fires `ClusterDown` or cascading alerts for all services simultaneously
- All health check endpoints unresponsive

---

## Impact Assessment

| Impact | Severity |
|--------|----------|
| All 6 services unavailable | Platform-wide |
| Active flight tracking lost | Patient safety critical |
| Emergency dispatch blocked | Cannot assign aircraft to new emergencies |
| Patient records inaccessible | Clinical decision support lost |
| Monitoring blind | No observability during recovery |

---

## Immediate Actions (< 5 minutes)

**Step 1 — Declare P1 All-Hands incident. Page everyone simultaneously:**
```
Page: On-call → Team Lead → VP Engineering → CEO/Medical Director
Channels: #aeromed-critical-alerts, #flight-operations, #medical-ops
Message: "FULL CLUSTER DOWN. Activating RB-005 and DR failover. 
          All active crews: switch to emergency backup protocols NOW."
```

**Step 2 — Confirm scope of failure:**
```bash
kubectl get nodes
kubectl get pods -n aeromed-production
kubectl cluster-info
```

**Step 3 — Check if this is a kubectl/API server issue (not actual cluster failure):**
```bash
# Try switching context explicitly
kubectl config get-contexts
kubectl config use-context aeromed-production

# Ping cluster API
curl -k https://<cluster-api-endpoint>/healthz
```

**Step 4 — If cluster is truly down, initiate DR failover:**
```bash
./disaster-recovery/scripts/failover.sh
```

**Step 5 — Notify all active flight crews via satellite backup:**
Flight Ops Lead must contact each active crew directly to confirm status.

---

## Investigation Steps (run in parallel with Step 4)

6. **Check cloud provider status** — is this an AZ/region-level outage?
   - AWS Status: https://status.aws.amazon.com
   - GCP Status: https://status.cloud.google.com

7. **Check control plane components:**
   ```bash
   kubectl get pods -n kube-system
   kubectl describe pod kube-apiserver-<node> -n kube-system
   ```

8. **Check etcd health:**
   ```bash
   kubectl exec -n kube-system etcd-<master-node> -- \
     etcdctl endpoint health --cluster
   ```

9. **Check node disk/memory pressure:**
   ```bash
   kubectl describe nodes | grep -A5 "Conditions:"
   ```

10. **Check if a recent deployment caused cascading failure:**
    ```bash
    kubectl get events -n aeromed-production --sort-by=.lastTimestamp | tail -50
    ```

---

## Failover Procedure (Primary → DR Cluster)

```bash
# 1. Execute automated failover script
./disaster-recovery/scripts/failover.sh

# 2. Verify DR cluster is healthy
kubectl config use-context aeromed-dr
kubectl get nodes
kubectl get pods -n aeromed-production

# 3. Run health checks against DR cluster
./disaster-recovery/scripts/health-check-all.sh

# 4. Confirm DNS has updated (wait up to 60s for Route53 TTL)
dig aeromed.internal +short
nslookup aeromed.internal
```

---

## Primary Cluster Recovery (after DR failover is stable)

```bash
# 1. Diagnose and fix root cause in primary cluster
# 2. Restore primary cluster to healthy state
kubectl get nodes  # All should be Ready
kubectl get pods -n aeromed-production  # All should be Running

# 3. Sync any data written to DR back to primary
# (Handled by Postgres replication — confirm no data divergence)

# 4. Switch traffic back to primary (scheduled maintenance window)
./disaster-recovery/scripts/failover.sh --target=primary

# 5. Decommission DR active state
```

---

## Rollback Procedure

If DR cluster failover causes further issues:
```bash
# Attempt to restore primary cluster and switch back
kubectl config use-context aeromed-production
./disaster-recovery/scripts/health-check-all.sh

# If primary is healthy, revert DNS
# (Update Route53 record or load balancer to point back to primary)
```

---

## Post-Incident Checklist

- [ ] All Tier 1 services restored (RTO verified)
- [ ] All active flights confirmed safe and crews accounted for
- [ ] Root cause identified (hardware, network, software, cloud provider)
- [ ] DR failover duration recorded (should be < 5 min for Tier 1)
- [ ] Data consistency verified across primary and DR clusters
- [ ] HIPAA and regulatory notifications filed if required
- [ ] Full post-mortem scheduled (mandatory; within 48 hours)
- [ ] Architecture review scheduled: identify single points of failure

---

## Escalation Path

- **0 min:** On-call declares P1 and pages all stakeholders simultaneously
- **5 min:** DR failover must be underway
- **15 min (DR not working):** Activate manual emergency protocols
  - Contact hospital receiving units directly
  - ATC manual coordination for all active flights
  - All dispatches held until comms restored
