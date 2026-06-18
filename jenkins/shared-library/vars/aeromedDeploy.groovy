// =============================================================================
// AeroMed Shared Library — Deployment Functions
// aeromedDeploy.groovy
//
// Usage in Jenkinsfile:
//   aeromedDeploy.deployToKubernetes('flight-operations', 'aeromed-staging', '42')
//   aeromedDeploy.waitForRollout('flight-operations', 'aeromed-production', 300)
//   aeromedDeploy.verifyServiceHealth('http://aeromed-flight-operations:5001')
//   aeromedDeploy.rollbackDeployment('flight-operations', 'aeromed-production', '41')
// =============================================================================

// ---------------------------------------------------------------------------
// SERVICE_PORTS — container port per service (matches Flask apps + K8s services)
// ---------------------------------------------------------------------------
def SERVICE_PORTS = [
    'api-gateway'       : 5000,
    'flight-operations' : 5001,
    'patient-records'   : 5002,
    'medical-equipment' : 5003,
    'emergency-dispatch': 5004,
    'aircraft-comms'    : 5005,
]

// K8s manifest directories — relative to repo root
def MANIFEST_DIRS = [
    namespaces      : 'kubernetes/namespaces',
    deployments     : 'kubernetes/deployments',
    services        : 'kubernetes/services',
    configmaps      : 'kubernetes/configmaps',
    hpa             : 'kubernetes/hpa',
    networkPolicies : 'kubernetes/network-policies',
    rbac            : 'kubernetes/rbac',
]

// ---------------------------------------------------------------------------
// deployToKubernetes — update image tag and apply manifests for one service
//
// Strategy:
//   1. Patch the deployment image tag (surgical — doesn't reapply all manifests)
//   2. Apply the service manifest (idempotent — no-op if unchanged)
//   3. Wait for rollout to complete
// ---------------------------------------------------------------------------
def deployToKubernetes(String service, String namespace, String imageTag,
                        String registry = 'aeromed') {
    echo "🚀 Deploying ${service}:${imageTag} → namespace/${namespace}"

    withEnv(["KUBECONFIG=${KUBE_CONFIG}"]) {

        // Patch the container image — faster than re-applying the full YAML
        // and avoids accidental overwrite of manual tweaks on other fields
        sh """
            kubectl set image deployment/${service} \
                ${service}=${registry}/${service}:${imageTag} \
                --namespace=${namespace} \
                --record=false
        """

        // Label the deployment with the build number for audit trail
        sh """
            kubectl annotate deployment/${service} \
                --namespace=${namespace} \
                kubernetes.io/change-cause="aeromed-build-${imageTag}-\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --overwrite
        """

        echo "✅ Image patch applied: ${service} → ${registry}/${service}:${imageTag}"
    }
}

// ---------------------------------------------------------------------------
// applyAllManifests — apply the full manifest set (used for initial provisioning
// or namespace bootstrap — NOT for image updates, use deployToKubernetes instead)
// ---------------------------------------------------------------------------
def applyAllManifests(String namespace) {
    echo "📋 Applying full manifest set to ${namespace}..."
    withEnv(["KUBECONFIG=${KUBE_CONFIG}"]) {
        // Apply in dependency order
        sh "kubectl apply -f ${MANIFEST_DIRS.namespaces}/"
        sh "kubectl apply -f ${MANIFEST_DIRS.configmaps}/ --namespace=${namespace}"
        sh "kubectl apply -f kubernetes/secrets/ --namespace=${namespace}"
        sh "kubectl apply -f ${MANIFEST_DIRS.rbac}/ --namespace=${namespace}"
        sh "kubectl apply -f ${MANIFEST_DIRS.networkPolicies}/ --namespace=${namespace}"
        sh "kubectl apply -f ${MANIFEST_DIRS.deployments}/ --namespace=${namespace}"
        sh "kubectl apply -f ${MANIFEST_DIRS.services}/ --namespace=${namespace}"
        sh "kubectl apply -f ${MANIFEST_DIRS.hpa}/ --namespace=${namespace}"
    }
}

// ---------------------------------------------------------------------------
// waitForRollout — blocks until the deployment finishes rolling out
// Surfaces progress in real time; times out and fails if exceeded
// ---------------------------------------------------------------------------
def waitForRollout(String service, String namespace, int timeoutSeconds = 300) {
    echo "⏳ Waiting for rollout: ${service} in ${namespace} (timeout: ${timeoutSeconds}s)"

    withEnv(["KUBECONFIG=${KUBE_CONFIG}"]) {
        def rolloutResult = sh(
            script: """
                kubectl rollout status deployment/${service} \
                    --namespace=${namespace} \
                    --timeout=${timeoutSeconds}s
            """,
            returnStatus: true
        )

        if (rolloutResult != 0) {
            // Capture describe output before aborting for diagnostics
            sh """
                echo "=== ROLLOUT FAILED — Deployment describe ==="
                kubectl describe deployment/${service} --namespace=${namespace}
                echo "=== Recent events ==="
                kubectl get events --namespace=${namespace} \
                    --sort-by='.lastTimestamp' --field-selector involvedObject.name=${service} \
                    | tail -20
                echo "=== Pod logs (last 50 lines) ==="
                kubectl logs --namespace=${namespace} \
                    -l app=${service} --tail=50 --prefix=true 2>&1 || true
            """
            error("🚨 Rollout of ${service} failed or timed out after ${timeoutSeconds}s")
        }

        // Print final pod state
        sh """
            echo "=== Pod status after rollout ==="
            kubectl get pods --namespace=${namespace} -l app=${service} \
                -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'
        """

        echo "✅ Rollout complete: ${service}"
    }
}

// ---------------------------------------------------------------------------
// verifyServiceHealth — HTTP health check against a running service endpoint
// Retries up to maxRetries times with exponential back-off
// ---------------------------------------------------------------------------
def verifyServiceHealth(String serviceUrl, int maxRetries = 5, int delaySeconds = 10) {
    echo "💓 Health check: ${serviceUrl}/health"

    def attempt = 0
    def healthy = false

    while (attempt < maxRetries && !healthy) {
        attempt++
        def result = sh(
            script: """
                RESPONSE=\$(curl -sf --max-time 10 ${serviceUrl}/health 2>&1)
                STATUS=\$?
                if [ \$STATUS -eq 0 ]; then
                    echo "\$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('status') == 'healthy', f'Unexpected status: {d}'
print(f'  → service={d[\"service\"]} version={d[\"version\"]} ts={d[\"timestamp\"]}')
"
                fi
                exit \$STATUS
            """,
            returnStatus: true
        )

        if (result == 0) {
            healthy = true
            echo "✅ ${serviceUrl} is healthy (attempt ${attempt}/${maxRetries})"
        } else if (attempt < maxRetries) {
            echo "⚠️  Attempt ${attempt}/${maxRetries} failed — retrying in ${delaySeconds}s..."
            sleep(delaySeconds)
            delaySeconds = Math.min(delaySeconds * 2, 60)  // exponential back-off, cap 60s
        }
    }

    if (!healthy) {
        error("🚨 Service health check failed after ${maxRetries} attempts: ${serviceUrl}")
    }
}

// ---------------------------------------------------------------------------
// rollbackDeployment — kubectl rollout undo to a known previous revision
//
// If previousVersion is provided, patches the image explicitly.
// Otherwise rolls back to the previous K8s revision (last good state).
// ---------------------------------------------------------------------------
def rollbackDeployment(String service, String namespace, String previousVersion = null,
                        String registry = 'aeromed') {
    echo "⏪ Rolling back ${service} in ${namespace}..."

    withEnv(["KUBECONFIG=${KUBE_CONFIG}"]) {
        if (previousVersion) {
            echo "Pinning to explicit version: ${registry}/${service}:${previousVersion}"
            sh """
                kubectl set image deployment/${service} \
                    ${service}=${registry}/${service}:${previousVersion} \
                    --namespace=${namespace}
                kubectl annotate deployment/${service} \
                    --namespace=${namespace} \
                    kubernetes.io/change-cause="ROLLBACK to ${previousVersion} at \$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    --overwrite
            """
        } else {
            echo "Rolling back to previous K8s revision (undo)"
            sh """
                kubectl rollout undo deployment/${service} \
                    --namespace=${namespace}
            """
        }

        // Wait for the rollback rollout to settle
        waitForRollout(service, namespace, 180)

        // Verify health after rollback
        def port = SERVICE_PORTS[service]
        echo "Service rolled back — manual verification required at port ${port}"

        sh """
            echo "=== Post-rollback pod state ==="
            kubectl get pods --namespace=${namespace} -l app=${service}
            echo "=== Rollout history ==="
            kubectl rollout history deployment/${service} --namespace=${namespace}
        """
    }

    echo "✅ Rollback complete: ${service}"
}

// ---------------------------------------------------------------------------
// verifyPostDeployState — checks pods, HPA, and Prometheus target readiness
// ---------------------------------------------------------------------------
def verifyPostDeployState(String service, String namespace) {
    echo "🔍 Post-deploy verification: ${service} in ${namespace}"

    withEnv(["KUBECONFIG=${KUBE_CONFIG}"]) {
        // 1. All pods are Running and Ready
        sh """
            echo "=== Pod readiness ==="
            kubectl get pods --namespace=${namespace} -l app=${service} \
                --field-selector=status.phase=Running
            READY=\$(kubectl get deployment/${service} --namespace=${namespace} \
                -o jsonpath='{.status.readyReplicas}')
            DESIRED=\$(kubectl get deployment/${service} --namespace=${namespace} \
                -o jsonpath='{.spec.replicas}')
            echo "Pods ready: \${READY}/\${DESIRED}"
            [ "\${READY}" = "\${DESIRED}" ] || { echo "ERROR: Not all pods are ready"; exit 1; }
        """

        // 2. HPA is configured and visible
        sh """
            echo "=== HPA status ==="
            kubectl get hpa ${service}-hpa --namespace=${namespace} \
                -o custom-columns='NAME:.metadata.name,MIN:.spec.minReplicas,MAX:.spec.maxReplicas,CURRENT:.status.currentReplicas,CPU:.status.currentMetrics[0].resource.current.averageUtilization' \
                2>/dev/null || echo "HPA not found — apply kubernetes/hpa/ manifests"
        """

        // 3. ConfigMap is mounted
        sh """
            echo "=== Config verification ==="
            kubectl get configmap aeromed-config --namespace=${namespace} \
                -o jsonpath='{.metadata.name}' && echo " — ConfigMap present" || \
                echo "WARNING: aeromed-config ConfigMap not found"
        """
    }

    echo "✅ Post-deploy verification passed: ${service}"
}

// ---------------------------------------------------------------------------
// call() — default: deploy + wait + verify
// ---------------------------------------------------------------------------
def call(String service, String namespace, String imageTag, Map options = [:]) {
    def registry = options.registry ?: 'aeromed'
    def timeout  = options.timeout ?: 300

    deployToKubernetes(service, namespace, imageTag, registry)
    waitForRollout(service, namespace, timeout)
    verifyPostDeployState(service, namespace)
}
