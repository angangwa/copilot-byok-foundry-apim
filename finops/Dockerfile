# Minimal image for the FinOps "heartbeat" — runs the stdlib-only seeder once per
# scheduled execution of the Container Apps Job. No Azure CLI needed: the App
# Insights connection string is injected via APPLICATIONINSIGHTS_CONNECTION_STRING.
FROM python:3.12-slim
WORKDIR /app
COPY seed-usage.py .
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "seed-usage.py"]
