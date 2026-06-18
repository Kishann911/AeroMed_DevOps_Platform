import os
import time
from datetime import datetime, timezone
from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "patient-records")
PORT = int(os.getenv("PORT", 5002))

REQUEST_COUNT = Counter("requests_total", "Total requests", ["method", "endpoint", "service"])
RESPONSE_TIME = Histogram("response_time_seconds", "Response time", ["endpoint", "service"])
ACTIVE_CONNECTIONS = Gauge("active_connections", "Active connections", ["service"])

MOCK_PATIENTS = [
    {
        "id": "PAT-2024-001",
        "name": "Patient-001",
        "age_range": "45-55",
        "condition_severity": "critical",
        "diagnosis_code": "I21.9",
        "transport_status": "in_transit",
        "assigned_aircraft": "N-AERO1",
        "attending_paramedic": "Medic-07",
        "vitals": {
            "heart_rate": 98,
            "blood_pressure": "88/60",
            "spo2_percent": 91,
            "gcs_score": 12,
        },
    },
    {
        "id": "PAT-2024-002",
        "name": "Patient-002",
        "age_range": "25-35",
        "condition_severity": "serious",
        "diagnosis_code": "S06.9",
        "transport_status": "delivered",
        "assigned_aircraft": "N-AERO2",
        "attending_paramedic": "Medic-03",
        "vitals": {
            "heart_rate": 112,
            "blood_pressure": "100/70",
            "spo2_percent": 96,
            "gcs_score": 14,
        },
    },
    {
        "id": "PAT-2024-003",
        "name": "Patient-003",
        "age_range": "65-75",
        "condition_severity": "stable",
        "diagnosis_code": "J44.1",
        "transport_status": "awaiting_transport",
        "assigned_aircraft": "N-AERO3",
        "attending_paramedic": "Medic-11",
        "vitals": {
            "heart_rate": 76,
            "blood_pressure": "130/85",
            "spo2_percent": 94,
            "gcs_score": 15,
        },
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
    response = jsonify({
        "service": SERVICE_NAME,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total_patients": len(MOCK_PATIENTS),
        "critical_count": sum(1 for p in MOCK_PATIENTS if p["condition_severity"] == "critical"),
        "patients": MOCK_PATIENTS,
    })
    RESPONSE_TIME.labels(endpoint="/api/status", service=SERVICE_NAME).observe(time.time() - start)
    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
