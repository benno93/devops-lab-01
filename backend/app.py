import os
from datetime import datetime, timezone

from flask import Flask, jsonify

app = Flask(__name__)

START_TIME = datetime.now(timezone.utc)


@app.get("/api/health")
def health():
    """Liveness/Readiness-Probe fuer Kubernetes."""
    return jsonify(status="ok"), 200


@app.get("/api/status")
def status():
    uptime = (datetime.now(timezone.utc) - START_TIME).total_seconds()
    return jsonify(
        service="devops-lab-01-backend",
        version=os.environ.get("APP_VERSION", "dev"),
        uptime_seconds=round(uptime, 1),
    )


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5001))
    app.run(host="0.0.0.0", port=port)
