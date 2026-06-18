// =============================================================================
// AeroMed Shared Library — Notification Functions
// aeromedNotify.groovy
//
// Usage in Jenkinsfile:
//   aeromedNotify.success(buildInfo)
//   aeromedNotify.failure(buildInfo, failedStage)
//   aeromedNotify.deploymentSummary(service, namespace, buildNumber, startTime)
//   aeromedNotify.p1Warning(p1Count)
// =============================================================================

// ---------------------------------------------------------------------------
// deploymentSummary — prints a structured summary table at pipeline end
// ---------------------------------------------------------------------------
def deploymentSummary(String service, String namespace, String buildNumber,
                       long startTimeMs, Map podInfo = [:]) {
    def durationSec = (System.currentTimeMillis() - startTimeMs) / 1000
    def durationStr = durationSec < 60
        ? "${(int)durationSec}s"
        : "${(int)(durationSec / 60)}m ${(int)(durationSec % 60)}s"

    def line = "═" * 60

    echo """
╔${line}╗
║  AeroMed Deployment Summary                              ║
╠${line}╣
║  Service     : ${service.padRight(42)} ║
║  Namespace   : ${namespace.padRight(42)} ║
║  Build       : #${buildNumber.padRight(41)} ║
║  Duration    : ${durationStr.padRight(42)} ║
║  Git Commit  : ${(env.GIT_COMMIT?.take(8) ?: 'unknown').padRight(42)} ║
║  Git Branch  : ${(env.GIT_BRANCH ?: 'unknown').padRight(42)} ║
║  Started By  : ${(env.BUILD_USER ?: 'automated').padRight(42)} ║
╚${line}╝"""

    // Print pod status table if info available
    withEnv(["KUBECONFIG=${KUBE_CONFIG}"]) {
        sh """
            echo ""
            echo "  Pod status in ${namespace}:"
            kubectl get pods --namespace=${namespace} -l app=${service} \
                -o custom-columns='  POD:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' \
                2>/dev/null || echo "  (unable to reach cluster)"
            echo ""
        """
    }
}

// ---------------------------------------------------------------------------
// success — green success banner (CI console output)
// ---------------------------------------------------------------------------
def success(String service, String buildNumber) {
    echo """
\033[0;32m
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   ✅  AeroMed Deployment SUCCESSFUL                     ║
║                                                          ║
║   Service : ${service.padRight(46)}║
║   Build   : #${buildNumber.padRight(45)}║
║   Time    : ${new Date().format("yyyy-MM-dd HH:mm:ss 'UTC'").padRight(46)}║
║                                                          ║
║   The platform is live and ready for operations.         ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
\033[0m"""
}

// ---------------------------------------------------------------------------
// failure — red failure banner with diagnosis hints
// ---------------------------------------------------------------------------
def failure(String service, String failedStage, String buildNumber) {
    echo """
\033[0;31m
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   ❌  AeroMed Deployment FAILED                         ║
║                                                          ║
║   Service      : ${service.padRight(42)}║
║   Build        : #${buildNumber.padRight(41)}║
║   Failed Stage : ${(failedStage ?: 'unknown').padRight(42)}║
║                                                          ║
║   Actions:                                               ║
║     1. Check console output above for error details      ║
║     2. Run: kubectl get events -n aeromed-production     ║
║     3. Set ROLLBACK=true and re-run to revert            ║
║     4. Check Grafana dashboard for anomalies             ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
\033[0m"""
}

// ---------------------------------------------------------------------------
// p1Warning — displayed when active P1 emergencies are detected pre-deploy
// ---------------------------------------------------------------------------
def p1Warning(int p1Count, int p2Count = 0) {
    echo """
\033[1;33m
╔══════════════════════════════════════════════════════════╗
║   ⚠️   ACTIVE EMERGENCY ALERT                           ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║   P1 (Critical) active dispatches : ${String.valueOf(p1Count).padRight(21)}║
║   P2 (Serious)  active dispatches : ${String.valueOf(p2Count).padRight(21)}║
║                                                          ║
║   Deploying during an active P1 event may briefly        ║
║   degrade response capability during the rolling update. ║
║                                                          ║
║   Recommended: wait for dispatches to clear, then deploy ║
║   Override: approve the INPUT step below to proceed.     ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
\033[0m"""
}

// ---------------------------------------------------------------------------
// rollbackStarted — printed when automatic rollback is triggered
// ---------------------------------------------------------------------------
def rollbackStarted(String service, String namespace) {
    echo """
\033[1;35m
╔══════════════════════════════════════════════════════════╗
║   ⏪  AUTOMATIC ROLLBACK INITIATED                      ║
╠══════════════════════════════════════════════════════════╣
║                                                          ║
║   Service   : ${service.padRight(44)}║
║   Namespace : ${namespace.padRight(44)}║
║                                                          ║
║   Rolling back to the previous stable revision.          ║
║   Monitor: kubectl rollout status deploy/${service}      ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
\033[0m"""
}

// ---------------------------------------------------------------------------
// smokeTestReport — prints tabular smoke test results
// ---------------------------------------------------------------------------
def smokeTestReport(Map<String, Boolean> results) {
    echo "\n  ── Smoke Test Results ──────────────────────────────"
    results.each { svc, passed ->
        def icon   = passed ? "✅" : "❌"
        def status = passed ? "PASS" : "FAIL"
        echo "  ${icon}  ${svc.padRight(28)} ${status}"
    }
    echo "  ────────────────────────────────────────────────────"

    def failedCount = results.values().count { !it }
    if (failedCount > 0) {
        error("${failedCount} smoke test(s) failed — deployment cannot proceed")
    }
}

// ---------------------------------------------------------------------------
// stagingApprovalGate — input step displayed before production deploy
// ---------------------------------------------------------------------------
def stagingApprovalGate(String service, String buildNumber) {
    def line = "─" * 58
    echo """
\033[1;36m
  ${line}
   🔐  PRODUCTION DEPLOY GATE — Manual Approval Required
  ${line}
   Service  : ${service}
   Build    : #${buildNumber}
   Staging  : Smoke tests PASSED ✅
  ${line}
\033[0m"""
}

// ---------------------------------------------------------------------------
// call() — default invocation: post-pipeline summary
// ---------------------------------------------------------------------------
def call(String result, String service, String buildNumber, long startTimeMs) {
    if (result == 'SUCCESS') {
        success(service, buildNumber)
    } else {
        failure(service, env.FAILED_STAGE ?: 'unknown', buildNumber)
    }
}
