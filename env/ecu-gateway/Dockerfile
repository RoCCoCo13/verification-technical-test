FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends procps iproute2 curl && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir grpcio==1.66.1 grpcio-tools==1.66.1 protobuf==5.28.2 aiohttp==3.10.5
WORKDIR /opt/tcu
COPY proto/vehicle_ecu.proto /opt/tcu/proto/
RUN python -m grpc_tools.protoc -I/opt/tcu/proto --python_out=/opt/tcu --grpc_python_out=/opt/tcu vehicle_ecu.proto
COPY common/dltlog.py ecu-gateway/adbd.py ecu-gateway/gateway.py ecu-gateway/entrypoint.sh /opt/tcu/
# AAOS-like filesystem layout
COPY ecu-gateway/android/system /system
COPY ecu-gateway/android/vendor /vendor
COPY ecu-gateway/tcu_cal.json /vendor/etc/calibration/tcu_cal.json
RUN mkdir -p /data /sdcard /vendor/bin && chmod +x /system/bin/* /opt/tcu/entrypoint.sh
ENV PATH="/system/bin:/vendor/bin:${PATH}"
EXPOSE 5555 8081
ENTRYPOINT ["/opt/tcu/entrypoint.sh"]
