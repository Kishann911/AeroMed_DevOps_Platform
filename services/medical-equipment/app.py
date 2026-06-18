import os
import time
from datetime import datetime, timezone
from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "medical-equipment")
PORT = int(os.getenv("PORT", 5003))

REQUEST_COUNT = Counter("requests_total", "Total requests", ["method", "endpoint", "service"])
RESPONSE_TIME = Histogram("response_time_seconds", "Response time", ["endpoint", "service"])
ACTIVE_CONNECTIONS = Gauge("active_connections", "Active connections", ["service"])

MOCK_EQUIPMENT = [
    {
        "id": "EQ-001",
        "equipment_type": "ventilator",
        "model": "Zoll Z Vent",
        "status": "in_use",
        "aircraft_id": "N-AERO1",
        "battery_level_percent": 78,
        "last_calibrated": "2024-01-10T08:00:00Z",
        "hours_remaining": 4.2,
    },
    {
        "id": "EQ-002",
        "equipment_type": "defibrillator",
        "model": "ZOLL X Series",
        "status": "operational",
        "aircraft_id": "N-AERO2",
        "battery_level_percent": 95,
        "last_calibrated": "2024-01-14T06:00:00Z",
        "hours_remaining": 8.0,
    },
    {
        "id": "EQ-003",
        "equipment_type": "IV_pump",
        "model": "Smiths CADD-Solis",
        "status": "in_use",
        "aircraft_id": "N-AERO1",
        "battery_level_percent": 62,
        "last_calibrated": "2024-01-12T09:00:00Z",
        "hours_remaining": 3.1,
    },
    {
        "id": "EQ-004",
        "equipment_type": "ventilator",
        "model": "Hamilton C1",
        "status": "maintenance",
        "aircraft_id": None,
        "battery_level_percent": 0,
        "last_calibrated": "2024-01-08T07:00:00Z",
        "hours_remaining": 0,
    },
    {
        "id": "EQ-005",
        "equipment_type": "defibrillator",
        "model": "Philips HeartStart",
        "status": "operational",
        "aircraft_id": "N-AERO3",
        "battery_level_percent": 88,
        "last_calibrated": "2024-01-13T11:00:00Z",
        "hours_remaining": 6.5,
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
        "total_equipment": len(MOCK_EQUIPMENT),
        "operational_count": sum(1 for e in MOCK_EQUIPMENT if e["status"] == "operational"),
        "in_use_count": sum(1 for e in MOCK_EQUIPMENT if e["status"] == "in_use"),
        "maintenance_count": sum(1 for e in MOCK_EQUIPMENT if e["status"] == "maintenance"),
        "equipment": MOCK_EQUIPMENT,
    })
    RESPONSE_TIME.labels(endpoint="/api/status", service=SERVICE_NAME).observe(time.time() - start)
    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
