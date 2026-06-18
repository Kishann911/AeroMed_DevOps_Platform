# RB-001 — Service Pod Failure

**Severity:** P2 (P1 if Tier 1 service)
**Last Updated:** 2026-06-16

---

## Symptoms

- AlertManager fires `ServiceDown` or `PodNotReady`
- Grafana "Platform Health" stat panel drops below 6
- `/health` endpoint returns non-200 or times out
- `kubectl get pods -n aeromed-production` shows `CrashLoopBackOff`, `Error`, or `Pending`

---

## Impact Assessment

| Affected Service | Patient Impact | Operational Impact |
|-----------------|---------------|--------------------|
| flight-operations | Active flight tracking degraded | Aircraft positions may be stale |
| emergency-dispatch | New emergency assignments blocked | Dispatch backlog grows |
| aircraft-comms | Crew communication lost | **P1 — escalate immediately** |
| patient-records | Medical history unavailable | Crews rely on verbal handoff |
| medical-equipment | Equipment telemetry offline | Manual monitoring required |
| api-gateway | External API calls fail | Internal services unaffected |

---

## Immediate Actions (< 5 minutes)

1. Check pod status across the namespace:
   ```bash
   kubectl get pods -n aeromed-production
   ```

2. Identify the failing pod and describe it:
   ```bash
   kubectl describe pod <failing-pod-name> -n aeromed-production
   ```
   Look for: `Events` section, `Last State`, `Restart Count`, resource pressure warnings.

3. Check recent logs:
   ```bash
   kubectl logs <failing-pod-name> -n aeromed-production --previous --tail=100
   ```

4. Attempt a rolling restart of the deployment:
   ```bash
   kubectl rollout restart deployment/<service-name> -n aeromed-production
   ```

5. Monitor rollout progress:
   ```bash
   kubectl rollout status deployment/<service-name> -n aeromed-production
   ```

---

## Investigation Steps

6. Check if the issue is resource-related:
   ```bash
   kubectl top pods -n aeromed-production
   kubectl describe node <node-name>
   ```

7. Check recent deployments (was something just deployed?):
   ```bash
   kubectl rollout history deployment/<service-name> -n aeromed-production
   ```

8. Check ConfigMap/Secret availability:
   ```bash
   kubectl get configmap,secret -n aeromed-production | grep <service-name>
   ```

9. Check if the issue affects multiple services (possible node or network failure):
   ```bash
   kubectl get pods -n aeromed-production -o wide
   ```

---

## Resolution Steps

**If restart fixes the issue:**
- Confirm all replicas are ready: `kubectl get pods -n aeromed-production`
- Run health check: `./disaster-recovery/scripts/health-check-all.sh`
- Document in post-incident log

**If restart does not fix the issue:**
10. Roll back to the previous deployment revision:
    ```bash
    kubectl rollout undo deployment/<service-name> -n aeromed-production
    kubectl rollout status deployment/<service-name> -n aeromed-production
    ```

11. If rollback fails, scale to zero and back:
    ```bash
    kubectl scale deployment/<service-name> --replicas=0 -n aeromed-production
    kubectl scale deployment/<service-name> --replicas=3 -n aeromed-production
    ```

---

## Rollback Procedure

```bash
# Check rollout history
kubectl rollout history deployment/<service-name> -n aeromed-production

# Roll back to previous version
kubectl rollout undo deployment/<service-name> -n aeromed-production

# Roll back to a specific revision
kubectl rollout undo deployment/<service-name> --to-revision=<N> -n aeromed-production
```

---

## Post-Incident Checklist

- [ ] Service restored and health checks passing
- [ ] Root cause identified
- [ ] Incident logged in incident tracker
- [ ] If caused by bad deployment: CI/CD pipeline reviewed
- [ ] Runbook updated if steps were insufficient
- [ ] Post-mortem scheduled if P1 or RTO was exceeded

---

## Escalation Path

- **0–5 min:** On-call engineer handles independently
- **5–10 min (Tier 1 service):** Page team lead
- **10+ min (any Tier 1):** Page VP Engineering + activate RB-005 if full cluster
