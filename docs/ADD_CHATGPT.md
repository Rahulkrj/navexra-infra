# Adding ChatGPT (subscription) to the LLM Gateway

The `codex-adapter` service exposes your ChatGPT Plus/Pro subscription as an
OpenAI-compatible API via the official OpenAI Codex CLI (`codex exec`). It sits
behind LiteLLM exactly like `claude-wrapper`:

```
client ──▶ litellm:4000 ──▶ codex-adapter:8020 ──▶ codex exec (ChatGPT login)
```

> **Terms of service.** Like the Claude path, driving a consumer ChatGPT
> subscription from a server is a gray area — keep it strictly single-user and
> low-volume. Headless runs share the same rate window as your interactive
> ChatGPT/Codex sessions. The adapter uses the official CLI (`codex exec`), a
> read-only sandbox, and a throwaway working directory.

## 1. One-time login (device-code flow, works headless)

```bash
docker compose -f docker-compose.llm.yml --env-file .env.llm build codex-adapter
docker compose -f docker-compose.llm.yml --env-file .env.llm \
  run --rm codex-adapter codex login --device-auth
# Visit the printed URL on any device, enter the code, sign in with your
# ChatGPT account. Credentials land in the codex_config volume and the CLI
# auto-refreshes them afterwards.
```

Alternative: log in on your laptop (`codex login`), then copy
`~/.codex/auth.json` into the volume:

```bash
docker compose -f docker-compose.llm.yml --env-file .env.llm up -d codex-adapter
docker cp ~/.codex/auth.json codex-adapter:/root/.codex/auth.json
docker restart codex-adapter
```

## 2. Verify

```bash
curl -s http://127.0.0.1:8020/health          # expect {"status":"ok","logged_in":true}
./scripts/smoke-test.sh                       # full end-to-end test
```

## 3. Use it

`POST /v1/chat/completions` on LiteLLM with `"model": "chatgpt"` (or
`"gpt-codex"`). Model resolution:

- `chatgpt` / `gpt-codex` → the Codex CLI's current default model — this keeps
  working when OpenAI deprecates model names.
- Pin a model by setting `CODEX_MODEL=` in `.env.llm` (e.g. `gpt-5.4`), or add
  another `model_list` entry in `llm/litellm-config.yaml` with
  `model: openai/<model-id>`.
- `CODEX_REASONING_EFFORT` (low|medium|high) trades speed for quality; `low`
  is the sensible chat default.

## Notes / limits

- Non-streaming under the hood; `stream=true` is answered with a single SSE
  chunk after completion, so streaming clients still work but see the answer
  arrive at once.
- `codex exec` reports no token usage, so LiteLLM spend logs show 0 tokens for
  these models.
- Every request is a fresh `codex exec` process (~a few seconds of overhead).
