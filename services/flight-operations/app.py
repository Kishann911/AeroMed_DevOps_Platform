import os
import time
from datetime import datetime, timezone
from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "flight-operations")
PORT = int(os.getenv("PORT", 5001))

REQUEST_COUNT = Counter("requests_total", "Total requests", ["method", "endpoint", "service"])
RESPONSE_TIME = Histogram("response_time_seconds", "Response time", ["endpoint", "service"])
ACTIVE_CONNECTIONS = Gauge("active_connections", "Active connections", ["service"])

MOCK_FLIGHTS = [
    {
        "id": "FLT-2024-001",
        "aircraft_id": "N-AERO1",
        "origin": "Denver International",
        "destination": "St. Mary's Medical Center",
        "status": "en_route",
        "patient_on_board": True,
        "estimated_arrival": "2024-01-15T14:30:00Z",
        "altitude_ft": 12500,
        "speed_knots": 180,
    },
    {
        "id": "FLT-2024-002",
        "aircraft_id": "N-AERO2",
        "origin": "Colorado Springs",
        "destination": "University Hospital",
        "status": "landed",
        "patient_on_board": False,
        "estimated_arrival": "2024-01-15T13:15:00Z",
        "altitude_ft": 0,
        "speed_knots": 0,
    },
    {
        "id": "FLT-2024-003",
        "aircraft_id": "N-AERO3",
        "origin": "AeroMed Base Alpha",
        "destination": "Rural Trauma Site 7",
        "status": "dispatched",
        "patient_on_board": False,
        "estimated_arrival": "2024-01-15T15:00:00Z",
        "altitude_ft": 8200,
        "speed_knots": 195,
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
        "active_flights": len(MOCK_FLIGHTS),
        "flights": MOCK_FLIGHTS,
    })
    RESPONSE_TIME.labels(endpoint="/api/status", service=SERVICE_NAME).observe(time.time() - start)
    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
