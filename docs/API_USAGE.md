# LLM Gateway — Complete API Reference

Base URLs (all serve the same API):

| calling from | base URL |
|---|---|
| internet (production) | `https://llm.infra.navexra.com` |
| the VPS / local machine | `http://localhost:4000` |
| docker containers on `infra_db_net` (n8n, your apps) | `http://litellm:4000` |

Authentication: every request needs `Authorization: Bearer <key>` — either
the master key (admin only) or a virtual key (apps).

---

## 1. Models

| model name | backend | best for | notes |
|---|---|---|---|
| `claude-sonnet` | Claude subscription | general chat + coding | full streaming |
| `claude-opus` | Claude subscription | hardest problems | full streaming |
| `claude-haiku` | Claude subscription | fast/cheap tasks | full streaming |
| `chatgpt` | ChatGPT subscription | general chat | streaming is simulated (answer arrives in one chunk); usage reports 0 tokens |
| `gpt-codex` | ChatGPT subscription | alias of `chatgpt` | same |
| `cursor-composer` | Cursor subscription | agentic coding tasks | non-streaming; usage reports 0 tokens |

List live: `GET /v1/models`

```bash
curl https://llm.infra.navexra.com/v1/models -H "Authorization: Bearer <key>"
```

---

## 2. Chat completions

`POST /v1/chat/completions` — standard OpenAI schema.

```bash
curl https://llm.infra.navexra.com/v1/chat/completions \
  -H "Authorization: Bearer <key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user",   "content": "Explain docker networks in 3 lines"}
    ],
    "temperature": 0.7,
    "max_tokens": 500,
    "stream": false
  }'
```

Response (OpenAI format):

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "claude-sonnet",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "..."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 12, "completion_tokens": 48, "total_tokens": 60}
}
```

Streaming: set `"stream": true` → Server-Sent Events (`data: {...chunk}` lines,
terminated by `data: [DONE]`). Claude models stream token-by-token; the
ChatGPT/Cursor backends compute fully first, then deliver in one chunk.

Unsupported OpenAI params are silently dropped (`drop_params: true`), so any
standard OpenAI client works unchanged.

### SDK examples

Python:

```python
from openai import OpenAI

client = OpenAI(base_url="https://llm.infra.navexra.com/v1", api_key="<key>")

# plain
r = client.chat.completions.create(
    model="chatgpt",
    messages=[{"role": "user", "content": "Hi"}],
)
print(r.choices[0].message.content)

# streaming
for chunk in client.chat.completions.create(
    model="claude-sonnet",
    messages=[{"role": "user", "content": "Write a haiku"}],
    stream=True,
):
    print(chunk.choices[0].delta.content or "", end="")
```

Node.js:

```javascript
import OpenAI from "openai";
const client = new OpenAI({
  baseURL: "https://llm.infra.navexra.com/v1",
  apiKey: "<key>",
});
const r = await client.chat.completions.create({
  model: "cursor-composer",
  messages: [{ role: "user", content: "Refactor this function..." }],
});
console.log(r.choices[0].message.content);
```

LangChain (python):

```python
from langchain_openai import ChatOpenAI
llm = ChatOpenAI(base_url="https://llm.infra.navexra.com/v1",
                 api_key="<key>", model="claude-sonnet")
```

n8n: OpenAI credential → Base URL `http://litellm:4000/v1`, API key = a
virtual key. Then pick any model name from the table.

---

## 3. Key management (master key required)

Create a virtual key:

```bash
curl -X POST https://llm.infra.navexra.com/key/generate \
  -H "Authorization: Bearer <master-key>" -H "Content-Type: application/json" \
  -d '{
    "key_alias": "my-app",
    "models": ["claude-sonnet", "chatgpt"],
    "duration": "90d",
    "rpm_limit": 30,
    "max_budget": 0
  }'
# → {"key": "sk-...", ...}   give this to the app
```

Useful fields: `models` (allowlist; omit = all), `duration` (`30d`, `12mo`;
omit = never expires), `rpm_limit`/`tpm_limit` (rate limits),
`metadata` (free-form tags).

Other endpoints:

```bash
# inspect a key
curl "https://llm.infra.navexra.com/key/info?key=sk-..." -H "Authorization: Bearer <master-key>"
# update limits/models on an existing key
curl -X POST https://llm.infra.navexra.com/key/update \
  -H "Authorization: Bearer <master-key>" -H "Content-Type: application/json" \
  -d '{"key": "sk-...", "rpm_limit": 60}'
# revoke
curl -X POST https://llm.infra.navexra.com/key/delete \
  -H "Authorization: Bearer <master-key>" -H "Content-Type: application/json" \
  -d '{"keys": ["sk-..."]}'
# spend/usage per key
curl "https://llm.infra.navexra.com/key/info?key=sk-..." -H "Authorization: Bearer <master-key>"
```

Admin UI (same features, point-and-click):
`https://llm.infra.navexra.com/ui` — log in with the master key.

---

## 4. Health & monitoring

```bash
curl https://llm.infra.navexra.com/health/liveliness      # "I'm alive!" (no auth)
curl https://llm.infra.navexra.com/health/readiness       # readiness + db status
# backend healths (VPS-local only):
curl http://127.0.0.1:8000/health   # claude-wrapper
curl http://127.0.0.1:8020/health   # codex-adapter ({"logged_in": true} = ChatGPT ok)
curl http://127.0.0.1:8010/health   # cursor-adapter
# full end-to-end test (VPS, repo root):
./scripts/smoke-test.sh
```

---

## 5. Errors & what they mean

| code | meaning | fix |
|---|---|---|
| 401 | bad/missing Bearer key | check key; mint via `/key/generate` |
| 400 `Invalid model name` | model not in `llm/litellm-config.yaml` or not allowed for this key | check `/v1/models` with your key; restart litellm after config edits |
| 429 | rate limit (key rpm/tpm, or the subscription's own window) | slow down; subscription limits are shared with your interactive usage |
| 502 from `chatgpt`/`cursor-composer` | adapter's CLI call failed; detail contains the CLI error | often auth: re-login codex / check `CURSOR_API_KEY` |
| 503 `Codex is not logged in` | ChatGPT device login missing on this machine | run the `codex login --device-auth` compose command |
| 504 | backend exceeded timeout (600 s) | reduce prompt size / retry |
| `Not logged in` / 401 inside a *Claude* response | `CLAUDE_CODE_OAUTH_TOKEN` expired/invalid | re-mint with `claude setup-token`, update `.env.llm`, recreate claude-wrapper |

---

## 6. Practical notes

- **Spend logs** for Claude models are real token counts; ChatGPT/Cursor
  report 0 (their CLIs don't expose usage). Request *counts* per key are
  always logged.
- **Latency**: ChatGPT/Cursor spawn a CLI process per request — expect a few
  seconds of overhead; Claude responses are faster.
- **Rate windows**: subscription backends share limits with your own
  interactive use of the same accounts. Keep server traffic single-user and
  low-volume (see ToS note in README).
- **Adding models**: new entry in `llm/litellm-config.yaml` →
  `docker compose -f docker-compose.llm.yml --env-file .env.llm restart litellm`.
