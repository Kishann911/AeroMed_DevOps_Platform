import os
import time
import threading
from datetime import datetime, timezone
from flask import Flask, jsonify, request
import requests as http_client
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "api-gateway")
PORT = int(os.getenv("PORT", 5000))

REQUEST_COUNT = Counter("requests_total", "Total requests", ["method", "endpoint", "service"])
RESPONSE_TIME = Histogram("response_time_seconds", "Response time", ["endpoint", "service"])
ACTIVE_CONNECTIONS = Gauge("active_connections", "Active connections", ["service"])

BACKEND_SERVICES = {
    "flight-operations": os.getenv("FLIGHT_OPS_URL", "http://aeromed-flight-operations:5001"),
    "patient-records": os.getenv("PATIENT_RECORDS_URL", "http://aeromed-patient-records:5002"),
    "medical-equipment": os.getenv("MEDICAL_EQUIPMENT_URL", "http://aeromed-medical-equipment:5003"),
    "emergency-dispatch": os.getenv("EMERGENCY_DISPATCH_URL", "http://aeromed-emergency-dispatch:5004"),
    "aircraft-comms": os.getenv("AIRCRAFT_COMMS_URL", "http://aeromed-aircraft-comms:5005"),
}

# Simulated failure registry: {service_name: expiry_timestamp}
_failure_registry: dict = {}
_failure_lock = threading.Lock()


def is_service_degraded(service_name: str) -> bool:
    with _failure_lock:
        expiry = _failure_registry.get(service_name)
        if expiry is None:
            return False
        if time.time() > expiry:
            del _failure_registry[service_name]
            return False
        return True


@app.before_request
def before_request():
    ACTIVE_CONNECTIONS.labels(service=SERVICE_NAME).inc()


@app.after_request
def after_request(response):
    ACTIVE_CONNECTIONS.labels(service=SERVICE_NAME).dec()
    return response


@app.route("/health")
def health():
    REQUEST_COUNT.labels(method="GET", endpoint="/health", service=SERVICE_NAME).inc()
    return jsonify({
        "status": "healthy",
        "service": SERVICE_NAME,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "version": "1.0.0",
    })


@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.route("/api/status")
def api_status():
    REQUEST_COUNT.labels(method="GET", endpoint="/api/status", service=SERVICE_NAME).inc()
    return jsonify({
        "service": SERVICE_NAME,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "backend_services": list(BACKEND_SERVICES.keys()),
        "gateway_status": "operational",
    })


@app.route("/api/all-status")
def all_status():
    start = time.time()
    REQUEST_COUNT.labels(method="GET", endpoint="/api/all-status", service=SERVICE_NAME).inc()

    results = {}
    for svc_name, base_url in BACKEND_SERVICES.items():
        if is_service_degraded(svc_name):
            results[svc_name] = {
                "status": "degraded",
                "reason": "simulated_failure",
                "health": None,
                "data": None,
            }
            continue
        svc_result = {"status": "unknown", "health": None, "data": None}
        try:
            health_resp = http_client.get(f"{base_url}/health", timeout=5)
            svc_result["health"] = health_resp.json()
            svc_result["status"] = "healthy" if health_resp.status_code == 200 else "unhealthy"
        except Exception as exc:
            svc_result["status"] = "unreachable"
            svc_result["error"] = str(exc)
        try:
            data_resp = http_client.get(f"{base_url}/api/status", timeout=5)
            svc_result["data"] = data_resp.json()
        except Exception:
            pass
        results[svc_name] = svc_result

    overall = "healthy" if all(r["status"] == "healthy" for r in results.values()) else "degraded"
    RESPONSE_TIME.labels(endpoint="/api/all-status", service=SERVICE_NAME).observe(time.time() - start)
    return jsonify({
        "gateway": SERVICE_NAME,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "overall_status": overall,
        "services": results,
    })


@app.route("/simulate/failure", methods=["POST"])
def simulate_failure():
    REQUEST_COUNT.labels(method="POST", endpoint="/simulate/failure", service=SERVICE_NAME).inc()
    payload = request.get_json(force=True) or {}
    svc = payload.get("service")
    duration = int(payload.get("duration_seconds", 30))

    if svc not in BACKEND_SERVICES:
        return jsonify({"error": f"Unknown service '{svc}'. Valid: {list(BACKEND_SERVICES.keys())}"}), 400

    with _failure_lock:
        _failure_registry[svc] = time.time() + duration

    return jsonify({
        "message": f"Service '{svc}' marked as degraded for {duration} seconds",
        "service": svc,
        "duration_seconds": duration,
        "expires_at": datetime.fromtimestamp(time.time() + duration, tz=timezone.utc).isoformat(),
    })


@app.route("/api/<service_name>/<path:subpath>", methods=["GET", "POST", "PUT", "DELETE"])
def proxy(service_name, subpath):
    REQUEST_COUNT.labels(method=request.method, endpoint=f"/api/{service_name}/{subpath}", service=SERVICE_NAME).inc()
    base_url = BACKEND_SERVICES.get(service_name)
    if not base_url:
        return jsonify({"error": f"Unknown service: {service_name}"}), 404
    if is_service_degraded(service_name):
        return jsonify({"error": f"Service '{service_name}' is currently degraded (simulated failure)"}), 503
    try:
        resp = http_client.request(
            method=request.method,
            url=f"{base_url}/{subpath}",
            headers={k: v for k, v in request.headers if k.lower() != "host"},
            json=request.get_json(silent=True),
            params=request.args,
            timeout=10,
        )
        return resp.content, resp.status_code, {"Content-Type": resp.headers.get("Content-Type", "application/json")}
    except Exception as exc:
        return jsonify({"error": "Upstream error", "detail": str(exc)}), 502


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
