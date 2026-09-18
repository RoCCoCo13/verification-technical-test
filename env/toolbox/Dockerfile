# Tester workstation image: adb, tshark, Robot Framework, gRPC tooling.
# Used by the model solution CI and available to candidates who cannot install adb locally.
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends adb tshark tcpdump curl jq netcat-openbsd procps \
 && rm -rf /var/lib/apt/lists/*
COPY toolbox/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
COPY proto/vehicle_ecu.proto /opt/proto/vehicle_ecu.proto
COPY toolbox/bashrc /root/.bashrc
WORKDIR /work
CMD ["bash"]
