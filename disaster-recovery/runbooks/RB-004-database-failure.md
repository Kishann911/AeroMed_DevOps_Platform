# RB-004 — Database Failure

**Severity:** P1 (patient-records DB) / P2 (supporting DBs)
**Last Updated:** 2026-06-16

---

## Symptoms

- AlertManager fires `DatabaseDown` or `PostgresReplicationLag`
- `patient-records` service returns 503 with "database connection failed"
- Grafana "Patient Records — Error Rate" spikes to >50%
- `kubectl logs` shows repeated `FATAL: connection refused` or `too many connections`
- Backup job fails to connect

---

## Impact Assessment

| Impact | Description |
|--------|-------------|
| **Patient records** | Patient history, allergies, medications unavailable |
| **Emergency dispatch** | Cannot link patient records to active dispatches |
| **Compliance** | HIPAA requires audit log continuity — database downtime is a reportable event |
| **Data loss risk** | Depends on replication lag at time of failure (RPO: 15 min) |

---

## Immediate Actions (< 5 minutes)

1. Confirm the database pod is down:
   ```bash
   kubectl get pods -n aeromed-production | grep postgres
   kubectl describe pod <postgres-pod> -n aeromed-production
   ```

2. Check database service connectivity from within the cluster:
   ```bash
   kubectl run db-check --rm -it --image=postgres:15 -n aeromed-production \
     -- psql -h aeromed-postgres -U aeromed -c "SELECT 1;"
   ```

3. Check database logs:
   ```bash
   kubectl logs -n aeromed-production deployment/aeromed-postgres --tail=200
   ```

4. Check persistent volume status:
   ```bash
   kubectl get pvc -n aeromed-production
   kubectl describe pvc aeromed-postgres-data -n aeromed-production
   ```

---

## Investigation Steps

5. **Connection pool exhaustion (too many connections):**
   ```bash
   # Check current connections
   kubectl exec -n aeromed-production deployment/aeromed-postgres -- \
     psql -U aeromed -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"
   ```

   If connection limit hit:
   ```bash
   # Terminate idle connections older than 5 minutes
   kubectl exec -n aeromed-production deployment/aeromed-postgres -- \
     psql -U aeromed -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity 
       WHERE state = 'idle' AND query_start < now() - interval '5 minutes';"
   ```

6. **Disk full:**
   ```bash
   kubectl exec -n aeromed-production deployment/aeromed-postgres -- df -h /var/lib/postgresql/data
   ```

   If disk full: resize PVC or clear WAL archives.

7. **Replication lag (standby is behind):**
   ```bash
   kubectl exec -n aeromed-production deployment/aeromed-postgres -- \
     psql -U aeromed -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
   ```

---

## Resolution Steps

**If database pod crashed — attempt restart:**
```bash
kubectl rollout restart deployment/aeromed-postgres -n aeromed-production
kubectl rollout status deployment/aeromed-postgres -n aeromed-production
```

**If primary database is unrecoverable — promote standby:**
```bash
# 1. Confirm standby replication state
kubectl exec -n aeromed-production deployment/aeromed-postgres-standby -- \
  psql -U aeromed -c "SELECT pg_is_in_recovery();"

# 2. Promote standby to primary
kubectl exec -n aeromed-production deployment/aeromed-postgres-standby -- \
  pg_ctl promote -D /var/lib/postgresql/data

# 3. Update service selector to point to new primary
kubectl patch service aeromed-postgres -n aeromed-production \
  -p '{"spec":{"selector":{"role":"standby"}}}'
```

**If data corruption — restore from backup:**
```bash
# See restore.sh for full procedure
./disaster-recovery/scripts/restore.sh --service=postgres --timestamp=<YYYYMMDD_HHMM>
```

---

## Rollback Procedure

If the promoted standby causes further issues:
```bash
# Revert service selector to original primary (if primary recovers)
kubectl patch service aeromed-postgres -n aeromed-production \
  -p '{"spec":{"selector":{"role":"primary"}}}'
```

---

## Post-Incident Checklist

- [ ] Database restored and all application services reconnected
- [ ] Data integrity verified: row counts match pre-failure snapshot
- [ ] HIPAA incident report filed if patient data was inaccessible > 15 minutes
- [ ] Replication lag resolved; standby is caught up
- [ ] Backup restored successfully if restore was performed
- [ ] Root cause documented
- [ ] Post-mortem scheduled (mandatory for all P1)

---

## Escalation Path

- **0–3 min:** On-call handles
- **3 min (patient-records DB):** Page team lead + notify Medical Director
- **10 min:** Page VP Engineering; consider activating `restore.sh`
- **Any data loss confirmed:** Immediately notify Legal/Compliance (HIPAA obligation)
