FROM ghcr.io/astral-sh/uv:0.12.21@sha256:a7aed3216253ee804de3e2d8afa5073baa1a177335345d43845cd4165e43b711 AS uv
FROM python:3.12-slim-bookworm@sha256:e697c81897302a4c4333bade000d98038fbb21eb064f8ee1fd42d02ebcd9d337 AS builder
COPY --from=uv /uv /uvx /bin/
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
COPY src ./src
RUN uv sync --frozen --no-dev --no-editable
COPY make_scene.py ./
RUN .venv/bin/python make_scene.py

FROM builder AS test
COPY tests ./tests
RUN uv sync --frozen && uv run pytest && uv run ruff check . \
    && uv run ruff format --check . && uv run mypy src/onvif_simulator

FROM python:3.12-slim-bookworm@sha256:e697c81897302a4c4333bade000d98038fbb21eb064f8ee1fd42d02ebcd9d337 AS runtime
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN groupadd --gid 10001 simulator \
    && useradd --uid 10001 --gid simulator --no-create-home --shell /usr/sbin/nologin simulator \
    && mkdir -p /app/state \
    && chown simulator:simulator /app/state
WORKDIR /app
COPY --from=builder --chown=10001:10001 /app/.venv /app/.venv
COPY --from=builder --chown=10001:10001 /app/img /app/img
USER 10001:10001
EXPOSE 2020 8554
ENTRYPOINT ["onvif-simulator"]
