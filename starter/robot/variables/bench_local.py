import os
BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:8000")
API_KEY = os.environ.get("VEHICLE_API_KEY", "dev-key-001")
ADB_SERIAL = os.environ.get("ADB_SERIAL", "127.0.0.1:5555")
BODY_ECU_ADDR = os.environ.get("BODY_ECU_ADDR", "127.0.0.1:50051")
TRACES_DIR = os.environ.get("TRACES_DIR", "../traces")
