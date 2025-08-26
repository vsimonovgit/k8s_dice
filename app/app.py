from flask import Flask, jsonify, Response
import os, random, logging
from prometheus_client import Counter, Gauge, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)

# Log configuration
LOG_PATH = os.environ.get("LOG_PATH", "/var/log/app/dice.log")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler()
    ]
)

# Prometheus metrics
dice_rolls_total = Counter("dice_rolls_total", "Total dice rolls")
app_ready = Gauge("app_ready", "1 if app is ready, 0 otherwise")

def is_ready() -> bool:
    return os.environ.get("READY", "true").lower() in ("1", "true", "yes")

@app.get("/health")
def health():
    ok = is_ready()
    app_ready.set(1 if ok else 0)
    return (jsonify({"status": "ok"}), 200) if ok else (jsonify({"status": "not-ready"}), 500)

@app.get("/dice")
def dice():
    n = random.randint(1, 6)
    dice_rolls_total.inc()
    logging.info("Rolled dice: %s", n)
    return jsonify({"dice": n}), 200

@app.get("/metrics")
def metrics():
    app_ready.set(1 if is_ready() else 0)
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))