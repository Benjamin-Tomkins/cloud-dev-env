from fastapi import FastAPI
import socket
import logging
import os

app = FastAPI(title="Python API", version="1.0.0")

# Log to stdout for K8s (logs collected by kubelet)
logging.basicConfig(
    level=logging.INFO,
    format='{"timestamp":"%(asctime)s","level":"%(levelname)s","message":"%(message)s"}'
)
logger = logging.getLogger(__name__)

@app.get("/")
def root():
    logger.info("Root endpoint called")
    vault_injected = os.path.exists("/vault/secrets/config")
    return {
        "service": "python-api",
        "message": "Hello from Python!",
        "host": socket.gethostname(),
        "vault_injected": vault_injected
    }

@app.get("/health")
def health():
    return {"status": "healthy"}
