FROM ghcr.io/astral-sh/uv:0.12.21 AS uv
FROM python:3.12-slim AS builder
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
RUN uv sync --frozen && uv run pytest && uv run ruff check . && uv run ruff format --check .

FROM python:3.12-slim AS runtime
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
