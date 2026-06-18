import os
import time
from datetime import datetime, timezone
from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "emergency-dispatch")
PORT = int(os.getenv("PORT", 5004))

REQUEST_COUNT = Counter("requests_total", "Total requests", ["method", "endpoint", "service"])
RESPONSE_TIME = Histogram("response_time_seconds", "Response time", ["endpoint", "service"])
ACTIVE_CONNECTIONS = Gauge("active_connections", "Active connections", ["service"])

MOCK_DISPATCHES = [
    {
        "id": "DSP-2024-001",
        "emergency_type": "cardiac",
        "priority": "P1",
        "location_coordinates": {"lat": 39.7392, "lon": -104.9903},
        "location_description": "Interstate 70, Mile Marker 247",
        "response_time_minutes": 8,
        "status": "active",
        "requesting_agency": "Jefferson County EMS",
        "aircraft_assigned": "N-AERO1",
        "dispatch_time": "2024-01-15T13:47:00Z",
    },
    {
        "id": "DSP-2024-002",
        "emergency_type": "trauma",
        "priority": "P1",
        "location_coordinates": {"lat": 38.8339, "lon": -104.8214},
        "location_description": "Highway 24, Cascade Falls area",
        "response_time_minutes": 14,
        "status": "en_route",
        "requesting_agency": "El Paso County Sheriff",
        "aircraft_assigned": "N-AERO3",
        "dispatch_time": "2024-01-15T13:55:00Z",
    },
    {
        "id": "DSP-2024-003",
        "emergency_type": "respiratory",
        "priority": "P2",
        "location_coordinates": {"lat": 40.0150, "lon": -105.2705},
        "location_description": "Boulder Community Hospital",
        "response_time_minutes": 22,
        "status": "staging",
        "requesting_agency": "Boulder Community Hospital",
        "aircraft_assigned": None,
        "dispatch_time": "2024-01-15T14:02:00Z",
    },
]


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
    start = time.time()
    REQUEST_COUNT.labels(method="GET", endpoint="/api/status", service=SERVICE_NAME).inc()
    p1_count = sum(1 for d in MOCK_DISPATCHES if d["priority"] == "P1")
    response = jsonify({
        "service": SERVICE_NAME,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "active_dispatches": len(MOCK_DISPATCHES),
        "p1_count": p1_count,
        "avg_response_time_minutes": sum(d["response_time_minutes"] for d in MOCK_DISPATCHES) / len(MOCK_DISPATCHES),
        "dispatches": MOCK_DISPATCHES,
    })
    RESPONSE_TIME.labels(endpoint="/api/status", service=SERVICE_NAME).observe(time.time() - start)
    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
