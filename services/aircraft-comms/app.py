import os
import time
from datetime import datetime, timezone
from flask import Flask, jsonify
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

SERVICE_NAME = os.getenv("SERVICE_NAME", "aircraft-comms")
PORT = int(os.getenv("PORT", 5005))

REQUEST_COUNT = Counter("requests_total", "Total requests", ["method", "endpoint", "service"])
RESPONSE_TIME = Histogram("response_time_seconds", "Response time", ["endpoint", "service"])
ACTIVE_CONNECTIONS = Gauge("active_connections", "Active connections", ["service"])

MOCK_COMMS = [
    {
        "aircraft_id": "N-AERO1",
        "callsign": "AeroMed 1",
        "signal_strength": "strong",
        "frequency_mhz": 123.45,
        "last_contact_seconds_ago": 12,
        "comms_mode": "VHF/SATCOM",
        "telemetry_data": {
            "gps_lat": 39.7392,
            "gps_lon": -104.9903,
            "altitude_ft": 12500,
            "groundspeed_knots": 178,
            "heading_degrees": 45,
            "fuel_lbs": 3200,
            "engine_temp_c": 720,
            "cabin_pressure_psi": 14.2,
        },
    },
    {
        "aircraft_id": "N-AERO2",
        "callsign": "AeroMed 2",
        "signal_strength": "strong",
        "frequency_mhz": 123.45,
        "last_contact_seconds_ago": 8,
        "comms_mode": "VHF",
        "telemetry_data": {
            "gps_lat": 38.8099,
            "gps_lon": -104.8214,
            "altitude_ft": 0,
            "groundspeed_knots": 0,
            "heading_degrees": 0,
            "fuel_lbs": 4100,
            "engine_temp_c": 85,
            "cabin_pressure_psi": 14.7,
        },
    },
    {
        "aircraft_id": "N-AERO3",
        "callsign": "AeroMed 3",
        "signal_strength": "weak",
        "frequency_mhz": 123.45,
        "last_contact_seconds_ago": 47,
        "comms_mode": "SATCOM",
        "telemetry_data": {
            "gps_lat": 39.0142,
            "gps_lon": -105.1011,
            "altitude_ft": 8200,
            "groundspeed_knots": 192,
            "heading_degrees": 180,
            "fuel_lbs": 2800,
            "engine_temp_c": 710,
            "cabin_pressure_psi": 14.0,
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
    lost_count = sum(1 for c in MOCK_COMMS if c["signal_strength"] == "lost")
    response = jsonify({
        "service": SERVICE_NAME,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "aircraft_tracked": len(MOCK_COMMS),
        "signal_lost_count": lost_count,
        "communications": MOCK_COMMS,
    })
    RESPONSE_TIME.labels(endpoint="/api/status", service=SERVICE_NAME).observe(time.time() - start)
    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
