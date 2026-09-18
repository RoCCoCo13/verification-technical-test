FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends tcpdump && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir requests==2.32.3
COPY scenario-runner/run_scenarios.py /opt/run_scenarios.py
ENTRYPOINT ["python", "/opt/run_scenarios.py"]
