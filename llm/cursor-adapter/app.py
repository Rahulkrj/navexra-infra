"""Minimal OpenAI-compatible adapter over the Cursor CLI (`cursor-agent`).

Exposes POST /v1/chat/completions and shells out to:

    cursor-agent -p "<prompt>" --output-format json --model <model>

authenticated by CURSOR_API_KEY (a Cursor *User API key* — the officially
supported headless path). The agent runs in a throwaway working directory so it
cannot touch anything on the host.

This is intentionally small and non-streaming. `cursor-agent` is an *agentic
coding tool* with file-write access, so treat the exposed model as
"agentic coding", not a general chat completion.
"""

import json
import os
import secrets
import subprocess
import tempfile
import time
import uuid

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

ADAPTER_API_KEY = os.environ.get("ADAPTER_API_KEY", "")
CURSOR_API_KEY = os.environ.get("CURSOR_API_KEY", "")
DEFAULT_MODEL = os.environ.get("CURSOR_MODEL", "composer-2.5")
TIMEOUT = int(os.environ.get("CURSOR_TIMEOUT", "600"))

app = FastAPI(title="cursor-adapter", version="1.0.0")


class Message(BaseModel):
    role: str
    content: object  # str or list[content-block]


class ChatRequest(BaseModel):
    model: str | None = None
    messages: list[Message]
    # Accepted for OpenAI compatibility; ignored by cursor-agent.
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
    return "\n\n".join(lines).strip()


def _extract_text(stdout: str) -> str:
    """cursor-agent --output-format json emits structured output; fall back to
    raw text if the schema isn't what we expect."""
    stdout = stdout.strip()
    if not stdout:
        return ""
    # Try a single JSON object first.
    try:
        data = json.loads(stdout)
        if isinstance(data, dict):
            for key in ("result", "response", "text", "content", "message"):
                if isinstance(data.get(key), str) and data[key].strip():
                    return data[key].strip()
        if isinstance(data, list):
            # Stream-style array of events; take the last assistant text.
            texts = []
            for ev in data:
                if isinstance(ev, dict):
                    t = ev.get("text") or ev.get("result") or ev.get("content")
                    if isinstance(t, str):
                        texts.append(t)
            if texts:
                return texts[-1].strip()
    except json.JSONDecodeError:
        # Maybe newline-delimited JSON events.
        last_text = None
        for line in stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(ev, dict):
                t = ev.get("text") or ev.get("result") or ev.get("content")
                if isinstance(t, str):
                    last_text = t
        if last_text is not None:
            return last_text.strip()
    return stdout


def _run_cursor(prompt: str, model: str) -> str:
    if not CURSOR_API_KEY:
        raise HTTPException(status_code=500, detail="CURSOR_API_KEY is not set")
    env = dict(os.environ)
    env["CURSOR_API_KEY"] = CURSOR_API_KEY
    with tempfile.TemporaryDirectory(prefix="cursor-adapter-") as workdir:
        cmd = [
            "cursor-agent",
            "-p",
            prompt,
            # Required for headless runs; safe because workdir is a fresh,
            # empty temp directory that is deleted afterwards.
            "--trust",
            "--output-format",
            "json",
            "--model",
            model,
        ]
        try:
            proc = subprocess.run(
                cmd,
                cwd=workdir,
                env=env,
                capture_output=True,
                text=True,
                timeout=TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            raise HTTPException(status_code=504, detail="cursor-agent timed out")
        except FileNotFoundError:
            raise HTTPException(status_code=500, detail="cursor-agent binary not found")
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "cursor-agent failed").strip()
            raise HTTPException(status_code=502, detail=detail[:2000])
        return _extract_text(proc.stdout)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/v1/models")
def list_models(authorization: str | None = Header(default=None)) -> dict:
    _require_auth(authorization)
    return {
        "object": "list",
        "data": [
            {"id": DEFAULT_MODEL, "object": "model", "owned_by": "cursor"},
            {"id": "auto", "object": "model", "owned_by": "cursor"},
        ],
    }


@app.post("/v1/chat/completions")
def chat_completions(
    req: ChatRequest, authorization: str | None = Header(default=None)
):
    _require_auth(authorization)
    if req.stream:
        # Keep it simple: this adapter is non-streaming.
        raise HTTPException(
            status_code=400,
            detail="Streaming is not supported by cursor-adapter; set stream=false.",
        )
    model = req.model or DEFAULT_MODEL
    prompt = _flatten_prompt(req.messages)
    if not prompt:
        raise HTTPException(status_code=400, detail="No prompt content in messages")

    text = _run_cursor(prompt, model)

    return JSONResponse(
        {
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
            # cursor-agent doesn't report token usage; report zeros.
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            },
        }
    )
