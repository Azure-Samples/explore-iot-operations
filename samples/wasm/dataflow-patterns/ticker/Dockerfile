FROM python:3.12.13-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --disable-pip-version-check -r requirements.txt \
    && mkdir /health && chown 10001:10001 /health
COPY ticker.py .
USER 10001:10001
ENTRYPOINT ["python", "/app/ticker.py"]
