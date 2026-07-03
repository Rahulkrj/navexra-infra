"""Minimal OpenAI-compatible adapter over the OpenAI Codex CLI (`codex`).

Exposes POST /v1/chat/completions and shells out to:

    codex exec --skip-git-repo-check --sandbox read-only \
        --output-last-message <tmpfile> [--model <model>] - < prompt

authenticated by the ChatGPT Plus/Pro subscription credentials in
$CODEX_HOME/auth.json (created via `codex login` / `codex login --device-auth`;
the CLI refreshes tokens automatically as long as the file is writable).

The agent runs in a throwaway working directory with a read-only sandbox so it
cannot modify anything. Non-streaming under the hood; if a client asks for
`stream=true` the full completion is computed first and replayed as a single
SSE chunk (many clients default to streaming, so this keeps them working).
"""

import json
import os
import secrets
import subprocess
import tempfile
import time
import uuid

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

ADAPTER_API_KEY = os.environ.get("ADAPTER_API_KEY", "")
# Default model when a request doesn't name one (empty = let codex decide).
DEFAULT_MODEL = os.environ.get("CODEX_MODEL", "").strip()
# Optional: low | medium | high | none (maps to model_reasoning_effort).
REASONING_EFFORT = os.environ.get("CODEX_REASONING_EFFORT", "").strip()
TIMEOUT = int(os.environ.get("CODEX_TIMEOUT", "600"))
CODEX_HOME = os.environ.get("CODEX_HOME", "/root/.codex")

# Model aliases that mean "use the CLI's default model".
PASSTHROUGH_MODELS = {"", "default", "auto", "codex", "chatgpt"}

app = FastAPI(title="codex-adapter", version="1.0.0")


class Message(BaseModel):
    role: str
    content: object  # str or list[content-block]


class ChatRequest(BaseModel):
    model: str | None = None
    messages: list[Message]
    # Accepted for OpenAI compatibility; ignored by codex.
    temperature: float | None = None
    max_tokens: int | None = None
    stream: bool | None = False


def _require_auth(authorization: str | None) -> None:
    if not ADAPTER_API_KEY:
        return
    expected = f"Bearer {ADAPTER_API_KEY}"
    if not authorization or not secrets.compare_digest(authorization, expected):
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


def _content_to_text(content: object) -> str:
    """OpenAI allows content to be a string or a list of typed blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(str(block.get("text", "")))
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    return str(content)


def _flatten_prompt(messages: list[Message]) -> str:
    lines = []
    for m in messages:
        text = _content_to_text(m.content)
        if m.role == "system":
            lines.append(f"[System instructions]\n{text}")
        elif m.role == "user":
            lines.append(f"[User]\n{text}")
        elif m.role == "assistant":
            lines.append(f"[Assistant]\n{text}")
        else:
            lines.append(text)
    lines.append(
        "[Instructions]\nYou are answering as a chat assistant. "
        "Reply with the answer only. Do not run commands or modify files."
    )
    return "\n\n".join(lines).strip()


def _logged_in() -> bool:
    return os.path.isfile(os.path.join(CODEX_HOME, "auth.json"))


def _run_codex(prompt: str, model: str) -> str:
    if not _logged_in():
        raise HTTPException(
            status_code=503,
            detail=(
                "Codex is not logged in: missing auth.json in CODEX_HOME. "
                "Run: docker compose -f docker-compose.llm.yml --env-file .env.llm "
                "run --rm codex-adapter codex login --device-auth"
            ),
        )
    with tempfile.TemporaryDirectory(prefix="codex-adapter-") as workdir:
        out_file = os.path.join(workdir, "last-message.txt")
        cmd = [
            "codex",
            "exec",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            out_file,
            "--color",
            "never",
        ]
        if model not in PASSTHROUGH_MODELS:
            cmd += ["--model", model]
        elif DEFAULT_MODEL:
            cmd += ["--model", DEFAULT_MODEL]
        if REASONING_EFFORT:
            cmd += ["-c", f"model_reasoning_effort={json.dumps(REASONING_EFFORT)}"]
        cmd.append(prompt)
        try:
            proc = subprocess.run(
                cmd,
                cwd=workdir,
                capture_output=True,
                text=True,
                timeout=TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise HTTPException(status_code=504, detail="codex exec timed out")
        except FileNotFoundError:
            raise HTTPException(status_code=500, detail="codex binary not found")
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "codex exec failed").strip()
            raise HTTPException(status_code=502, detail=detail[:2000])
        try:
            with open(out_file, "r", encoding="utf-8") as fh:
                text = fh.read().strip()
        except OSError:
            text = ""
        if not text:
            # Fallback: the tail of stdout (codex prints the final answer last).
            text = (proc.stdout or "").strip()
        if not text:
            raise HTTPException(status_code=502, detail="codex returned no output")
        return text


def _completion_payload(model: str, text: str) -> dict:
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
        # codex exec doesn't report token usage; report zeros.
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "logged_in": _logged_in()}


@app.get("/v1/models")
def list_models(authorization: str | None = Header(default=None)) -> dict:
    _require_auth(authorization)
    ids = ["default"]
    if DEFAULT_MODEL:
        ids.append(DEFAULT_MODEL)
    return {
        "object": "list",
        "data": [{"id": i, "object": "model", "owned_by": "openai-codex"} for i in ids],
    }


@app.post("/v1/chat/completions")
def chat_completions(
    req: ChatRequest, authorization: str | None = Header(default=None)
):
    _require_auth(authorization)
    model = (req.model or DEFAULT_MODEL or "default").strip()
    prompt = _flatten_prompt(req.messages)
    if not prompt:
        raise HTTPException(status_code=400, detail="No prompt content in messages")

    text = _run_codex(prompt, model)

    if req.stream:
        # Fake streaming: compute fully, then replay as SSE so streaming
        # clients (OpenAI SDKs, n8n, etc.) work unchanged.
        chunk_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())

        def sse():
            first = {
                "id": chunk_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "delta": {"role": "assistant", "content": text},
                        "finish_reason": None,
                    }
                ],
            }
            last = {
                "id": chunk_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }
            yield f"data: {json.dumps(first)}\n\n"
            yield f"data: {json.dumps(last)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(sse(), media_type="text/event-stream")

    return JSONResponse(_completion_payload(model, text))
