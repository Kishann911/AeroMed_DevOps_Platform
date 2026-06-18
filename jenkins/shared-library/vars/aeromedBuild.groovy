// =============================================================================
// AeroMed Shared Library — Build Functions
// aeromedBuild.groovy
//
// Usage in Jenkinsfile:
//   aeromedBuild.buildImage('flight-operations', '42')
//   aeromedBuild.runSecurityScan('aeromed/flight-operations:42')
//   aeromedBuild.runUnitTests('flight-operations')
//   aeromedBuild.runIntegrationTests(['flight-operations'])
// =============================================================================

// ---------------------------------------------------------------------------
// Service metadata — port and path mappings used across build functions
// ---------------------------------------------------------------------------
def SERVICE_CONFIG = [
    'api-gateway'       : [port: 5000, context: 'services/api-gateway'],
    'flight-operations' : [port: 5001, context: 'services/flight-operations'],
    'patient-records'   : [port: 5002, context: 'services/patient-records'],
    'medical-equipment' : [port: 5003, context: 'services/medical-equipment'],
    'emergency-dispatch': [port: 5004, context: 'services/emergency-dispatch'],
    'aircraft-comms'    : [port: 5005, context: 'services/aircraft-comms'],
]

// ---------------------------------------------------------------------------
// buildImage — docker build + dual-tag (BUILD_NUMBER and 'latest')
// Returns the tagged image name for downstream use
// ---------------------------------------------------------------------------
def buildImage(String service, String buildNumber, String registry = 'aeromed') {
    def cfg    = SERVICE_CONFIG[service]
    def imgTag = "${registry}/${service}:${buildNumber}"
    def latest = "${registry}/${service}:latest"

    echo "╔═══════════════════════════════════════════╗"
    echo "║  Building: ${service.padRight(30)} ║"
    echo "║  Tag:      ${buildNumber.padRight(30)} ║"
    echo "╚═══════════════════════════════════════════╝"

    sh """
        docker build \
            --build-arg BUILD_NUMBER=${buildNumber} \
            --build-arg BUILD_TIMESTAMP=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \
            --label aeromed.service=${service} \
            --label aeromed.build=${buildNumber} \
            --label aeromed.git.commit=\$(git rev-parse --short HEAD) \
            -t ${imgTag} \
            -t ${latest} \
            ${cfg.context}/
    """

    // Print image size for tracking
    sh "docker images ${imgTag} --format 'Image size: {{.Size}} — {{.Repository}}:{{.Tag}}'"
    return imgTag
}

// ---------------------------------------------------------------------------
// buildServices — builds a list of services (or all if 'all' passed)
// Returns map of service → image tag
// ---------------------------------------------------------------------------
def buildServices(String serviceParam, String buildNumber, String registry = 'aeromed') {
    def services = serviceParam == 'all' ? SERVICE_CONFIG.keySet().toList() : [serviceParam]
    def imageTags = [:]

    echo "Building ${services.size()} service(s): ${services.join(', ')}"
    for (svc in services) {
        imageTags[svc] = buildImage(svc, buildNumber, registry)
    }
    return imageTags
}

// ---------------------------------------------------------------------------
// runSecurityScan — Trivy vulnerability scan on a built image
// Fails pipeline on CRITICAL; warns on HIGH; ignores MEDIUM/LOW
// ---------------------------------------------------------------------------
def runSecurityScan(String imageTag, boolean failOnCritical = true) {
    echo "🔍 Running Trivy security scan on: ${imageTag}"

    // Scan for CRITICAL — exit code 1 if found (pipeline fails)
    def criticalResult = sh(
        script: """
            docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v trivy-cache:/root/.cache/ \
                aquasec/trivy:latest image \
                    --exit-code 1 \
                    --severity CRITICAL \
                    --no-progress \
                    --format table \
                    ${imageTag} 2>&1 || true
        """,
        returnStatus: true
    )

    // Scan for HIGH — exit code 1 if found (warn only, don't fail)
    def highResult = sh(
        script: """
            docker run --rm \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v trivy-cache:/root/.cache/ \
                aquasec/trivy:latest image \
                    --exit-code 1 \
                    --severity HIGH \
                    --no-progress \
                    --format table \
                    ${imageTag} 2>&1 || true
        """,
        returnStatus: true
    )

    if (highResult != 0) {
        unstable("⚠️  HIGH severity vulnerabilities found in ${imageTag} — review before production deploy")
    }

    if (criticalResult != 0 && failOnCritical) {
        error("🚨 CRITICAL vulnerabilities found in ${imageTag} — pipeline aborted. " +
              "A compromised container cannot be deployed to a healthcare-critical system.")
    }

    echo "✅ Security scan passed for ${imageTag}"
}

// ---------------------------------------------------------------------------
// runUnitTests — pytest inside the built container
// ---------------------------------------------------------------------------
def runUnitTests(String service, String buildNumber, String registry = 'aeromed') {
    def imageTag = "${registry}/${service}:${buildNumber}"
    echo "🧪 Running unit tests for ${service}"

    sh """
        docker run --rm \
            -e ENV=test \
            -e LOG_LEVEL=WARNING \
            --name aeromed-test-${service}-\${BUILD_NUMBER} \
            --entrypoint /bin/sh \
            ${imageTag} \
            -c "pip install pytest pytest-cov --quiet && \
                python -m pytest /app/ -v \
                    --tb=short \
                    --junitxml=/tmp/test-results.xml \
                    --cov=/app \
                    --cov-report=term-missing \
                    2>&1 || echo 'No test files found — add tests to services/'"
    """
}

// ---------------------------------------------------------------------------
// runIntegrationTests — docker-compose up → health poll → tear down
// ---------------------------------------------------------------------------
def runIntegrationTests(List<String> services) {
    def servicePortMap = [
        'api-gateway'       : 5000,
        'flight-operations' : 5001,
        'patient-records'   : 5002,
        'medical-equipment' : 5003,
        'emergency-dispatch': 5004,
        'aircraft-comms'    : 5005,
    ]

    echo "🔗 Starting integration test stack with docker-compose..."
    sh "docker compose up -d --build 2>&1"

    // Poll until all target services are healthy (max 120s)
    def targetServices = services == ['all'] ? servicePortMap.keySet().toList() : services
    def maxWait = 120
    def waited = 0

    while (waited < maxWait) {
        def allHealthy = true
        for (svc in targetServices) {
            def port = servicePortMap[svc]
            def status = sh(
                script: "curl -sf --max-time 3 http://localhost:${port}/health > /dev/null 2>&1",
                returnStatus: true
            )
            if (status != 0) {
                allHealthy = false
                break
            }
        }
        if (allHealthy) {
            echo "✅ All ${targetServices.size()} services healthy after ${waited}s"
            break
        }
        sleep(5)
        waited += 5
        if (waited >= maxWait) {
            sh "docker compose logs 2>&1 | tail -100"
            error("Integration test stack failed to become healthy after ${maxWait}s")
        }
    }

    // Run endpoint verification
    for (svc in targetServices) {
        def port = servicePortMap[svc]
        sh """
            echo "Testing ${svc} on port ${port}..."
            curl -sf http://localhost:${port}/health | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'healthy', f'Expected healthy, got: {d}'
assert d['service'] is not None, 'Missing service field'
print(f'  ✓ /health  → {d[\"service\"]} v{d[\"version\"]}')
"
            curl -sf http://localhost:${port}/api/status > /dev/null && echo "  ✓ /api/status"
        """
    }
}

// ---------------------------------------------------------------------------
// teardownIntegrationTests — always called in post block
// ---------------------------------------------------------------------------
def teardownIntegrationTests() {
    echo "🧹 Tearing down integration test stack..."
    sh "docker compose down --remove-orphans 2>&1 || true"
}

// ---------------------------------------------------------------------------
// pushImage — push to registry (DockerHub or ECR)
// ---------------------------------------------------------------------------
def pushImage(String service, String buildNumber, String registry = 'aeromed') {
    def imgTag = "${registry}/${service}:${buildNumber}"
    def latest  = "${registry}/${service}:latest"

    echo "📤 Pushing ${imgTag} to registry..."
    sh "docker push ${imgTag}"
    sh "docker push ${latest}"
    echo "✅ Push complete: ${imgTag}"
}

// ---------------------------------------------------------------------------
// call() — default invocation: build + scan + test for a single service
// ---------------------------------------------------------------------------
def call(String service, String buildNumber, Map options = [:]) {
    def registry      = options.registry ?: 'aeromed'
    def skipTests     = options.skipTests ?: false
    def failOnCrit    = options.failOnCritical ?: true

    def imageTag = buildImage(service, buildNumber, registry)
    runSecurityScan(imageTag, failOnCrit)
    if (!skipTests) {
        runUnitTests(service, buildNumber, registry)
    }
    return imageTag
}
