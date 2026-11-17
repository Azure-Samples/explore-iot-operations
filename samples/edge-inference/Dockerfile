FROM python:3.12-slim-bookworm

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY collector.py inspection.py mqtt_client.py mqtt_transport.py ./
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
ENTRYPOINT ["python", "mqtt_client.py"]
CMD ["collect"]
