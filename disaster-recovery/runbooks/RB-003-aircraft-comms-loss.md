# RB-003 — Aircraft Communication Loss

**Severity:** P1 — TIER 1 INCIDENT
**Last Updated:** 2026-06-16

---

> **PATIENT SAFETY WARNING:** Loss of aircraft communication means flight crews cannot receive updated patient data, weather alerts, or ATC coordination. Active aircraft with critical patients are at risk. This runbook must be executed immediately upon alert. Do not wait to confirm the issue before alerting the flight operations team.

---

## Symptoms

- AlertManager fires `AircraftCommunicationLost`
- Grafana "Aircraft Comms — Uptime %" drops to 0%
- Flight crews report loss of telemetry feed
- GPS position data for active aircraft stops updating in `flight-operations` service
- `/health` endpoint for `aeromed-aircraft-comms` returns 503 or no response

---

## Impact Assessment

| Impact | Description |
|--------|-------------|
| **Active flights** | Position tracking lost; ATC coordination degraded |
| **Emergency dispatch** | Cannot confirm aircraft arrival ETAs |
| **Patient safety** | Crews cannot receive updated patient vitals or hospital routing |
| **Regulatory** | FAA/ICAO requires continuous aircraft tracking — regulatory breach risk |

---

## Immediate Actions (< 5 minutes)

**Step 1 — Alert flight operations team immediately (do not wait for diagnosis):**
```
Page: #flight-operations Slack channel + direct phone call to Flight Ops Lead
Message: "Aircraft communications service is DOWN. Activating RB-003. 
          All active crews: switch to satellite backup channel NOW."
```

**Step 2 — Check aircraft-comms service health:**
```bash
kubectl get pods -n aeromed-production -l app=aircraft-comms
kubectl describe deployment aircraft-comms -n aeromed-production
```

**Step 3 — Check recent logs for the communications service:**
```bash
kubectl logs -l app=aircraft-comms -n aeromed-production --tail=200 --previous
```

**Step 4 — Switch all active aircraft to satellite backup communication channel:**
```bash
# Notify dispatch system to use backup routing
kubectl exec -n aeromed-production deployment/emergency-dispatch -- \
  curl -X POST http://localhost:5004/api/comms/switch-to-backup
```
If exec fails, contact flight ops team to manually activate backup via radio.

**Step 5 — Attempt force pod restart with priority scheduling:**
```bash
kubectl rollout restart deployment/aircraft-comms -n aeromed-production
kubectl rollout status deployment/aircraft-comms -n aeromed-production --timeout=120s
```

**Step 6 — Notify all active flight crews of communication status:**
Dispatch team must contact each active crew via satellite backup to confirm:
- They are aware of the system outage
- They have an alternate communication plan
- Current patient status and ETA are confirmed verbally

---

## Investigation Steps

7. Check if the issue is network-related (not a pod issue):
   ```bash
   # From within cluster — test connectivity to telemetry endpoints
   kubectl run debug-net --rm -it --image=curlimages/curl -n aeromed-production \
     -- curl -v http://aircraft-comms:5005/health
   ```

8. Check if external telemetry ingest endpoint is reachable:
   ```bash
   # Check ingress/load balancer
   kubectl get ingress -n aeromed-production
   kubectl describe ingress aeromed-ingress -n aeromed-production
   ```

9. Check if a network policy is blocking traffic:
   ```bash
   kubectl get networkpolicy -n aeromed-production
   kubectl describe networkpolicy aircraft-comms-netpol -n aeromed-production
   ```

10. Check if the issue is at the cloud provider level (check AWS/GCP status page for the region).

---

## Resolution Steps

**If service-level issue (pod crash):**
```bash
kubectl rollout restart deployment/aircraft-comms -n aeromed-production
kubectl rollout status deployment/aircraft-comms -n aeromed-production
```

**If bad deployment caused the issue:**
```bash
kubectl rollout undo deployment/aircraft-comms -n aeromed-production
kubectl rollout status deployment/aircraft-comms -n aeromed-production
```

**If network policy blocking traffic:**
```bash
kubectl edit networkpolicy aircraft-comms-netpol -n aeromed-production
# Temporarily allow all ingress to diagnose, then re-restrict
```

**Confirm recovery:**
```bash
curl http://<service-endpoint>:5005/health
# Expected: {"status": "healthy", "telemetry": "connected"}
./disaster-recovery/scripts/health-check-all.sh
```

---

## Rollback Procedure

```bash
kubectl rollout undo deployment/aircraft-comms -n aeromed-production
kubectl rollout status deployment/aircraft-comms -n aeromed-production
kubectl get pods -n aeromed-production -l app=aircraft-comms
```

---

## Post-Incident Checklist

- [ ] Service restored and all active aircraft reconnected to primary channel
- [ ] Satellite backup channel deactivated (crews returned to primary)
- [ ] Flight operations lead confirms all crew accounted for
- [ ] Regulatory notification filed if outage exceeded 5 minutes (check FAA requirements)
- [ ] Root cause documented
- [ ] Full post-mortem scheduled (mandatory for all P1 incidents)
- [ ] Redundancy improvements identified (e.g., automatic satellite failover)

---

## Escalation Path

- **0 min:** On-call page fires via PagerDuty
- **0 min:** On-call engineer simultaneously alerts flight ops team (do not wait)
- **2 min (no resolution):** Page team lead
- **5 min (no resolution):** Page VP Engineering + CEO/Medical Director
- **Any time:** If active aircraft cannot be reached via any channel, contact ATC directly
