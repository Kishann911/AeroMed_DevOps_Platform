# RB-002 — Pod CrashLoopBackOff

**Severity:** P2 (P1 if Tier 1 service and multiple replicas failing)
**Last Updated:** 2026-06-16

---

## Symptoms

- `kubectl get pods -n aeromed-production` shows `CrashLoopBackOff` in STATUS column
- Restart count incrementing rapidly
- Grafana "CrashLoopBackOff Containers" stat panel shows non-zero value
- AlertManager fires `PodCrashLooping` alert

---

## Impact Assessment

A CrashLoopBackOff means the container starts, immediately exits, and Kubernetes keeps retrying with exponential backoff (10s → 20s → 40s → ... → 5min). During backoff periods the service is completely unavailable. If HPA cannot scale new replicas from a different image, the service may be entirely down.

---

## Immediate Actions (< 5 minutes)

1. Identify crashing pods:
   ```bash
   kubectl get pods -n aeromed-production | grep CrashLoop
   ```

2. Retrieve the crash reason from the previous container run:
   ```bash
   kubectl logs <pod-name> -n aeromed-production --previous
   ```

3. Describe the pod to see Kubernetes events:
   ```bash
   kubectl describe pod <pod-name> -n aeromed-production
   ```
   Key sections: `Last State`, `Exit Code`, `Events`.

4. Common exit codes and meanings:
   | Exit Code | Likely Cause |
   |-----------|-------------|
   | 1 | Application crash / unhandled exception |
   | 137 | OOM Kill (out of memory) — check resource limits |
   | 139 | Segfault |
   | 143 | SIGTERM not handled (graceful shutdown issue) |

---

## Investigation Steps

5. **OOM kill suspected (exit 137):** Check memory limits vs. actual usage:
   ```bash
   kubectl top pod <pod-name> -n aeromed-production
   kubectl describe pod <pod-name> -n aeromed-production | grep -A5 "Limits:"
   ```

6. **Application crash (exit 1):** Look for config/secret issues:
   ```bash
   kubectl get events -n aeromed-production --sort-by=.lastTimestamp | tail -20
   kubectl describe pod <pod-name> -n aeromed-production | grep -A10 "Environment:"
   ```

7. **Check if a bad ConfigMap or Secret was recently updated:**
   ```bash
   kubectl get configmap -n aeromed-production -o yaml | grep -A5 "creationTimestamp"
   ```

8. **Check if recent image was deployed with a bug:**
   ```bash
   kubectl describe deployment <service-name> -n aeromed-production | grep Image:
   ```

---

## Resolution Steps

**If OOM (exit 137):**
```bash
# Temporarily increase memory limit
kubectl patch deployment <service-name> -n aeromed-production \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"<container>","resources":{"limits":{"memory":"512Mi"}}}]}}}}'
```

**If config/secret issue:**
```bash
# Check and fix the ConfigMap, then restart
kubectl edit configmap <configmap-name> -n aeromed-production
kubectl rollout restart deployment/<service-name> -n aeromed-production
```

**If bad image:**
```bash
# Roll back to previous working image
kubectl rollout undo deployment/<service-name> -n aeromed-production
kubectl rollout status deployment/<service-name> -n aeromed-production
```

**If liveness probe is too aggressive (killing healthy pods):**
```bash
kubectl patch deployment <service-name> -n aeromed-production \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"<container>","livenessProbe":{"initialDelaySeconds":30,"failureThreshold":5}}]}}}}'
```

---

## Rollback Procedure

```bash
kubectl rollout undo deployment/<service-name> -n aeromed-production
kubectl rollout status deployment/<service-name> -n aeromed-production
kubectl get pods -n aeromed-production
```

---

## Post-Incident Checklist

- [ ] Root cause confirmed (OOM / config / bad image / probe)
- [ ] Fix applied and service running stably for 10+ minutes
- [ ] If OOM: resource request/limit updated in deployment manifest and committed to Git
- [ ] If bad image: CI pipeline gate reviewed (were tests passing?)
- [ ] Incident logged
- [ ] Post-mortem if Tier 1 or RTO exceeded

---

## Escalation Path

- **0–5 min:** On-call resolves independently
- **5+ min (Tier 1):** Page team lead; consider activating RB-001 rollback
