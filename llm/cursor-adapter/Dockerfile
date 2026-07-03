# Minimal OpenAI-compatible adapter over the Cursor CLI (cursor-agent).
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PATH="/root/.local/bin:${PATH}"

# curl is needed to install the Cursor CLI; ca-certificates for TLS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install the official Cursor CLI (provides `cursor-agent`).
RUN curl https://cursor.com/install -fsS | bash \
    && cursor-agent --version

WORKDIR /app
COPY requirements.txt ./
RUN pip install -r requirements.txt
COPY app.py ./

EXPOSE 8010

CMD ["sh", "-c", "uvicorn app:app --host 0.0.0.0 --port ${PORT:-8010}"]
