FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir fastapi==0.115.0 "uvicorn[standard]==0.30.6" httpx==0.27.2 pydantic==2.9.2
WORKDIR /opt/backend
COPY common/dltlog.py /opt/backend/
COPY backend/app /opt/backend/app
RUN mkdir -p /var/log/dlt
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
