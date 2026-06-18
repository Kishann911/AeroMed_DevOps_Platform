# AeroMed Platform — Deployment Guide

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | 24.0+ | https://docs.docker.com/desktop/ |
| Docker Compose | v2 (bundled) | Included with Docker Desktop |
| Python 3 | 3.10+ | `brew install python` / package manager |
| kubectl | 1.28+ | `brew install kubectl` |
| Minikube | 1.31+ | `brew install minikube` |
| Helm | 3.12+ | `brew install helm` |
| Terraform | 1.6+ | `brew install terraform` |

---

## Option A: Local Docker Compose (Recommended for Demo)

This is the fastest path. All 10 services start in under 2 minutes.

### 1. Clone and start

```bash
git clone <repo-url> AeroMed_DevOps_Platform
cd AeroMed_DevOps_Platform
chmod +x scripts/*.sh

./scripts/start.sh
```

The startup script will:
- Check Docker is running
- Build all 6 service images
- Start all containers including Prometheus, Grafana, AlertManager, Jenkins
- Wait up to 120 seconds for health checks to pass
- Print a status table with URLs

### 2. Verify all services are healthy

```bash
./scripts/status.sh
```

Expected output:
```
╔══════════════════════════════════════════════════════╗
║       AeroMed Platform — Health Status               ║
╚══════════════════════════════════════════════════════╝

  SERVICE                      STATUS    URL
  api-gateway                  HEALTHY   http://localhost:5000
  flight-operations            HEALTHY   http://localhost:5001
  patient-records              HEALTHY   http://localhost:5002
  medical-equipment            HEALTHY   http://localhost:5003
  emergency-dispatch           HEALTHY   http://localhost:5004
  aircraft-comms               HEALTHY   http://localhost:5005

  Infrastructure:
  prometheus                   HEALTHY   http://localhost:9090
  grafana                      HEALTHY   http://localhost:3000
  alertmanager                 HEALTHY   http://localhost:9093
  jenkins                      HEALTHY   http://localhost:8080

  Overall: ALL 6 AeroMed services are HEALTHY
```

### 3. Access services

| Service | URL | Credentials |
|---------|-----|-------------|
| API Gateway | http://localhost:5000/api/all-status | none |
| Grafana | http://localhost:3000 | admin / aeromed123 |
| Prometheus | http://localhost:9090 | none |
| AlertManager | http://localhost:9093 | none |
| Jenkins | http://localhost:8080 | admin / aeromed123 |

### 4. Stop the stack

```bash
./scripts/stop.sh
```

---

## Option B: Local Kubernetes with Minikube

Use this option to demonstrate HPA autoscaling and full K8s behaviour.

### 1. Start Minikube with sufficient resources

```bash
minikube start \
  --cpus=4 \
  --memory=8192 \
  --disk-size=20g \
  --kubernetes-version=v1.28.0 \
  --addons=ingress,metrics-server,dashboard
```

Verify the cluster is running:
```bash
kubectl cluster-info
kubectl get nodes
# Expected: 1 node in Ready state
```

### 2. Create namespace and apply manifests

```bash
# Create namespace
kubectl apply -f kubernetes/namespaces/

# Apply ConfigMaps and Secrets first
kubectl apply -f kubernetes/configmaps/ -n aeromed-production
kubectl apply -f kubernetes/secrets/ -n aeromed-production

# Deploy services
kubectl apply -f kubernetes/deployments/ -n aeromed-production
kubectl apply -f kubernetes/services/ -n aeromed-production

# Apply HPAs
kubectl apply -f kubernetes/hpa/ -n aeromed-production

# Apply ingress
kubectl apply -f kubernetes/ingress/ -n aeromed-production

# Apply network policies
kubectl apply -f kubernetes/network-policies/ -n aeromed-production

# Apply RBAC
kubectl apply -f kubernetes/rbac/ -n aeromed-production
```

### 3. Deploy monitoring stack

```bash
# Add Prometheus helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack (includes Prometheus, Grafana, AlertManager)
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n aeromed-monitoring \
  --create-namespace \
  --set grafana.adminPassword=aeromed123

# Apply custom Grafana dashboards
kubectl apply -f monitoring/grafana/datasources/ -n aeromed-monitoring
kubectl apply -f monitoring/grafana/dashboards/  -n aeromed-monitoring
```

### 4. Wait for pods to be ready

```bash
kubectl wait --for=condition=ready pod \
  --all -n aeromed-production \
  --timeout=300s
```

### 5. Access services via Minikube

```bash
# Get the Minikube IP
MINIKUBE_IP=$(minikube ip)
echo "Minikube IP: ${MINIKUBE_IP}"

# Port-forward individual services for local access
kubectl port-forward svc/api-gateway        5000:5000 -n aeromed-production &
kubectl port-forward svc/flight-operations  5001:5001 -n aeromed-production &
kubectl port-forward svc/patient-records    5002:5002 -n aeromed-production &
kubectl port-forward svc/medical-equipment  5003:5003 -n aeromed-production &
kubectl port-forward svc/emergency-dispatch 5004:5004 -n aeromed-production &
kubectl port-forward svc/aircraft-comms     5005:5005 -n aeromed-production &

# Port-forward monitoring
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n aeromed-monitoring &
kubectl port-forward svc/monitoring-grafana 3000:80 -n aeromed-monitoring &
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 -n aeromed-monitoring &
```

### 6. Verify the Kubernetes deployment

```bash
kubectl get pods -n aeromed-production
kubectl get hpa -n aeromed-production
kubectl get ingress -n aeromed-production
./scripts/status.sh
```

---

## Option C: AWS EKS (Production)

### Prerequisites

```bash
# Configure AWS credentials
aws configure

# Install eksctl
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl
```

### 1. Provision infrastructure with Terraform

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set region, cluster_name, node_instance_type

terraform init
terraform plan
terraform apply
```

Terraform creates:
- EKS cluster (2 node groups: t3.medium × 3 across 2 AZs)
- RDS PostgreSQL Multi-AZ
- ALB with TLS termination
- Route53 records
- S3 bucket for backups
- IAM roles for service accounts

### 2. Configure kubectl

```bash
aws eks update-kubeconfig \
  --name aeromed-production \
  --region us-east-1
kubectl get nodes
```

### 3. Deploy with kubectl

Follow the same steps as Option B (Minikube) from step 2 onwards.

### 4. Configure Jenkins

```bash
# Jenkins is deployed via Helm
helm repo add jenkins https://charts.jenkins.io
helm install jenkins jenkins/jenkins \
  -n jenkins \
  --create-namespace \
  --set controller.adminPassword=aeromed123 \
  --set controller.serviceType=LoadBalancer
```

---

## Running the Jenkins Pipeline

### 1. Access Jenkins

- **Docker Compose:** http://localhost:8080 (admin / aeromed123)
- **Kubernetes:** `kubectl get svc jenkins -n jenkins` (note the LoadBalancer IP)

### 2. Create a pipeline job

1. New Item → Pipeline
2. Name: `aeromed-platform-build`
3. Pipeline → Definition: `Pipeline script from SCM`
4. SCM: Git → Repository URL: `<your-repo-url>`
5. Script Path: `jenkins/Jenkinsfile`
6. Save → Build Now

### 3. Pipeline stages

The Jenkinsfile runs these stages in order:

| Stage | What it does |
|-------|-------------|
| Checkout | Clones repo, sets BUILD_ID label |
| Build | `docker build` for all 6 services in parallel |
| Unit Tests | `pytest` inside each service container |
| Security Scan | Trivy image vulnerability scan |
| Push Images | Pushes to ECR / Docker Hub (tag: `${BUILD_NUMBER}`) |
| Deploy Staging | `kubectl apply` to `aeromed-staging` namespace |
| Integration Tests | `./scripts/status.sh` + basic API smoke tests |
| Deploy Production | `kubectl apply` with `maxUnavailable: 0` rolling update |
| Smoke Tests | `./scripts/health-check-all.sh` |
| Notify | Slack notification: build result + deployment details |

---

## Verifying Everything Works

### Quick smoke test

```bash
# 1. All health endpoints return 200
for port in 5000 5001 5002 5003 5004 5005; do
  echo -n "Port $port: "
  curl -sf "http://localhost:$port/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))"
done

# 2. Aggregated status
curl -s http://localhost:5000/api/all-status | python3 -m json.tool

# 3. Prometheus is scraping all targets
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
targets=d['data']['activeTargets']
for t in targets:
    print(t['labels'].get('job','?'), t['health'])
"
```

### Full resilience demo

```bash
# Runs the complete 7-step demo with pause-to-narrate
./scripts/demo-full-recovery.sh

# Individual simulations:
./scripts/simulate-aircraft-comms-failure.sh
./scripts/simulate-service-outage.sh flight-operations 30
./scripts/simulate-traffic-surge.sh 60 1000 50
./scripts/simulate-pod-failure.sh
./scripts/simulate-node-pressure.sh 30 cpu

# Load test (60s, 20 concurrent workers)
python3 scripts/load-test.py --duration 60 --workers 20
```

---

## Common Issues and Fixes

### Docker: port already in use

```bash
# Find what's using port 5000
lsof -ti:5000 | xargs kill -9
# Or use a different port:
AEROMED_GATEWAY=http://localhost:15000 ./scripts/status.sh
```

### Docker: services unhealthy after start

```bash
# Check individual service logs
docker compose logs flight-operations --tail=50
docker compose logs api-gateway --tail=50

# Rebuild a specific service
docker compose build flight-operations
docker compose up -d flight-operations
```

### Grafana: "No data" in panels

Prometheus needs ~30s to scrape initial metrics. If panels still show no data:
1. Go to Prometheus: http://localhost:9090/targets
2. Verify all `aeromed-*` targets are UP (green)
3. Try the query `up{job=~"aeromed-.*"}` in Prometheus Graph
4. Check datasource: Grafana → Connections → Data Sources → Prometheus → Test

### Minikube: metrics-server not working (HPA shows `<unknown>`)

```bash
minikube addons enable metrics-server
kubectl rollout restart deployment metrics-server -n kube-system
kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=60s
kubectl top nodes  # Should now show CPU/memory
```

### Jenkins: pipeline fails at Docker build

Ensure Jenkins has Docker access:
```bash
# Docker Compose mode: Jenkins container has Docker socket mounted
# Kubernetes mode: Check the Jenkins service account has the right RBAC
kubectl describe serviceaccount jenkins -n jenkins
```

### AlertManager: not routing to Slack

1. Verify the Slack webhook URL in `monitoring/alertmanager/alertmanager.yml`
2. Replace `PLACEHOLDER` with a real webhook from your Slack workspace
3. Restart AlertManager: `docker compose restart alertmanager`
4. Test: `curl -X POST http://localhost:9093/api/v1/alerts ...`
