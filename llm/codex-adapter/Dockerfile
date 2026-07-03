# Minimal OpenAI-compatible adapter over the OpenAI Codex CLI (`codex`).
# Uses a ChatGPT Plus/Pro subscription via `codex login` credentials stored
# in the CODEX_HOME volume (/root/.codex/auth.json).
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    CODEX_HOME=/root/.codex

# nodejs/npm are only needed to install the Codex CLI (a native binary
# shipped via npm); ca-certificates for TLS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install the official OpenAI Codex CLI. Pin deliberately; bump on purpose.
RUN npm install -g @openai/codex \
    && codex --version

WORKDIR /app
COPY requirements.txt ./
RUN pip install -r requirements.txt
COPY app.py ./

EXPOSE 8020

CMD ["sh", "-c", "uvicorn app:app --host 0.0.0.0 --port ${PORT:-8020}"]
