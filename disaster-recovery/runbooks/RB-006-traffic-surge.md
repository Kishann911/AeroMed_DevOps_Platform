# RB-006 — Traffic Surge / Mass Casualty Event

**Severity:** P1
**Trigger:** Emergency mass-casualty event driving 10x normal request volume
**Last Updated:** 2026-06-16

---

## Symptoms

- Grafana "Request Rate per Service" shows 10x+ spike (normal: ~50 req/s; surge: 500+ req/s)
- HPA replicas at maximum for one or more services
- Response times climbing above 2-second SLO threshold
- AlertManager fires `HighRequestRate` or `HPAAtMaxReplicas`
- Emergency dispatch queue depth rapidly increasing
- `aeromed_emergency_dispatch_active_count` metric spiking

---

## Context

A mass-casualty event (multi-vehicle accident, building collapse, industrial incident) can simultaneously generate dozens of emergency dispatch requests and flight operation updates. The system must scale to handle this while maintaining sub-500ms p99 latency for the emergency-dispatch service specifically — delayed dispatch means delayed aircraft assignment.

---

## Impact Assessment

| Impact | Description |
|--------|-------------|
| **Emergency dispatch** | Queue backlog; assignments delayed |
| **Flight operations** | Increased concurrent position updates |
| **Patient records** | Spike in concurrent record lookups |
| **API gateway** | Rate limiting may block legitimate P1 traffic |

---

## Immediate Actions (< 5 minutes)

**Step 1 — Verify HPA has already scaled up automatically:**
```bash
kubectl get hpa -n aeromed-production
kubectl describe hpa emergency-dispatch-hpa -n aeromed-production
```
Expected: `REPLICAS` should be increasing toward `MAXPODS`. If HPA is not scaling, check:
```bash
kubectl get events -n aeromed-production | grep HorizontalPodAutoscaler
```

**Step 2 — If HPA is at max replicas and queue is still backing up, manually increase the maximum:**
```bash
kubectl patch hpa emergency-dispatch-hpa -n aeromed-production \
  -p '{"spec":{"maxReplicas":20}}'
kubectl patch hpa flight-operations-hpa -n aeromed-production \
  -p '{"spec":{"maxReplicas":15}}'
```

**Step 3 — Enable rate limiting bypass for P1 emergency dispatch traffic:**
```bash
# Patch api-gateway ConfigMap to whitelist emergency-dispatch from rate limits
kubectl patch configmap api-gateway-config -n aeromed-production \
  --type=merge -p '{"data":{"RATE_LIMIT_BYPASS_SERVICES":"emergency-dispatch,aircraft-comms"}}'
kubectl rollout restart deployment/api-gateway -n aeromed-production
```

**Step 4 — Activate warm standby nodes in secondary region:**
```bash
# Scale up standby node group (adjust for your cloud provider)
# AWS EKS example:
aws eks update-nodegroup-config \
  --cluster-name aeromed-dr \
  --nodegroup-name aeromed-workers \
  --scaling-config minSize=3,maxSize=20,desiredSize=10 \
  --region us-west-2

echo "Warm standby nodes scaling up in DR region. ETA: ~3 minutes."
```

---

## Investigation Steps

5. Monitor queue depth and response times in real time:
   ```bash
   # Watch HPA scaling decisions
   kubectl get hpa -n aeromed-production -w
   
   # Watch pod count
   kubectl get pods -n aeromed-production -w | grep emergency-dispatch
   ```

6. Check if the database is becoming a bottleneck:
   ```bash
   kubectl exec -n aeromed-production deployment/aeromed-postgres -- \
     psql -U aeromed -c "SELECT count(*), wait_event_type FROM pg_stat_activity GROUP BY wait_event_type;"
   ```

7. Check if resource quotas are blocking new pod creation:
   ```bash
   kubectl describe resourcequota -n aeromed-production
   ```
   If quota is the bottleneck:
   ```bash
   kubectl patch resourcequota aeromed-quota -n aeromed-production \
     --type=merge -p '{"spec":{"hard":{"pods":"100","requests.cpu":"50","requests.memory":"100Gi"}}}'
   ```

8. Check node capacity:
   ```bash
   kubectl describe nodes | grep -A5 "Allocated resources"
   ```
   If nodes are full, new pods will be `Pending` — activate additional nodes (Step 4).

---

## Resolution Steps

9. Once peak traffic subsides, scale HPA maxReplicas back to normal:
   ```bash
   # Restore to production-standard values
   kubectl patch hpa emergency-dispatch-hpa -n aeromed-production \
     -p '{"spec":{"maxReplicas":10}}'
   kubectl patch hpa flight-operations-hpa -n aeromed-production \
     -p '{"spec":{"maxReplicas":8}}'
   ```

10. Remove rate limiting bypass once traffic normalises:
    ```bash
    kubectl patch configmap api-gateway-config -n aeromed-production \
      --type=merge -p '{"data":{"RATE_LIMIT_BYPASS_SERVICES":""}}'
    kubectl rollout restart deployment/api-gateway -n aeromed-production
    ```

11. Scale down warm standby nodes in DR region:
    ```bash
    aws eks update-nodegroup-config \
      --cluster-name aeromed-dr \
      --nodegroup-name aeromed-workers \
      --scaling-config minSize=2,maxSize=5,desiredSize=2 \
      --region us-west-2
    ```

---

## Rollback Procedure

If any patches made the situation worse:
```bash
# Restore HPA to normal values
kubectl patch hpa emergency-dispatch-hpa -n aeromed-production \
  -p '{"spec":{"minReplicas":2,"maxReplicas":10}}'

# Remove api-gateway config patch
kubectl patch configmap api-gateway-config -n aeromed-production \
  --type=merge -p '{"data":{"RATE_LIMIT_BYPASS_SERVICES":""}}'

# Restart api-gateway
kubectl rollout restart deployment/api-gateway -n aeromed-production
```

---

## Post-Incident Checklist

- [ ] All dispatch queue items processed; no requests lost
- [ ] Response times back within SLO (p99 < 500ms for emergency-dispatch)
- [ ] HPA maxReplicas restored to production values
- [ ] Rate limiting bypass removed
- [ ] DR region scaled back down
- [ ] Cost impact assessed (overprovisioned nodes cost money)
- [ ] Load test scheduled to validate autoscaling can handle this pattern automatically in future
- [ ] Consider permanently raising HPA maxReplicas baseline given this event

---

## Escalation Path

- **0–2 min:** On-call handles HPA scaling check
- **2 min (HPA at max):** Manually increase replicas — no approval needed for P1
- **5 min (still degraded):** Page team lead; activate DR warm standby
- **10 min (dispatch queue backing up):** Page VP Engineering + Medical Director; evaluate manually routing some dispatches to backup system
