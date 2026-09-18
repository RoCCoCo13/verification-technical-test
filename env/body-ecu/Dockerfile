FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir grpcio==1.66.1 grpcio-tools==1.66.1 protobuf==5.28.2
WORKDIR /opt/bcm
COPY proto/vehicle_ecu.proto /opt/bcm/proto/
RUN python -m grpc_tools.protoc -I/opt/bcm/proto --python_out=/opt/bcm --grpc_python_out=/opt/bcm vehicle_ecu.proto
COPY common/dltlog.py /opt/bcm/
COPY body-ecu/server.py /opt/bcm/
COPY body-ecu/body_cal.json /etc/body_ecu/body_cal.json
RUN mkdir -p /var/log/dlt
EXPOSE 50051
CMD ["python", "/opt/bcm/server.py"]
