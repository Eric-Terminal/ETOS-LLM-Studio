---
title: Add Your First Provider
description: Connect OpenAI, Anthropic, Gemini, or any compatible service to ETOS LLM Studio, step by step, until your first message works.
---

# Add Your First Provider

A **provider** is the company supplying the LLM service — OpenAI, Anthropic, Google, or any service that exposes an "OpenAI-compatible" endpoint. ETOS LLM Studio ships with **no built-in model**; every conversation goes through a provider you add.

This page walks through adding your first provider in detail and confirming text chat works. Advanced configuration (header overrides, parameter expressions, raw JSON body) lives at the bottom — skip it on your first pass.

## Read This First

### Three Things to Have Ready

| Need | Where to get it |
| --- | --- |
| A working API key | From the vendor console. OpenAI: [platform.openai.com/api-keys](https://platform.openai.com/api-keys). Anthropic: [console.anthropic.com](https://console.anthropic.com). Google: [aistudio.google.com/apikey](https://aistudio.google.com/apikey). |
| The Base URL | Official vendors: see the table below. Third-party relays: look for "OpenAI compatible URL" or `base_url` in their docs. |
| At least one valid model ID | e.g. `gpt-4o`, `claude-3-7-sonnet-latest`, `gemini-2.5-pro`. **Model IDs are exact strings** — a single typo means "model not found". |

::: tip One Provider Is Enough at First
Configure just **one** stable provider on your first pass. Add a second only after chat is working.
:::

### Official Base URL Cheat Sheet

All addresses below are **base URLs** — fill in only to `/v1` (or the equivalent version segment). The app appends the actual endpoint path (`/chat/completions`, `/messages`, etc.) automatically.

| Vendor | API Format | Base URL |
| --- | --- | --- |
| OpenAI (Chat Completions endpoint) | `OpenAI Compatible` | `https://api.openai.com/v1` |
| OpenAI (Responses endpoint, for GPT-4.1 / GPT-5) | `OpenAI Responses` | `https://api.openai.com/v1` |
| Anthropic Claude | `Anthropic` | `https://api.anthropic.com/v1` |
| Google Gemini | `Gemini` | `https://generativelanguage.googleapis.com/v1beta` |
| Any "OpenAI-compatible" relay | `OpenAI Compatible` | The `base_url` from the relay's docs |

::: info OpenAI Compatible vs OpenAI Responses
- **OpenAI Compatible (Chat Completions)**: the legacy endpoint that nearly every third-party relay supports. If you're not on the official OpenAI endpoint, you almost certainly want this one.
- **OpenAI Responses**: the newer endpoint OpenAI recommends for GPT-4.1+. It supports richer reasoning summaries, tool use, and persistent state across turns. **Only the official OpenAI endpoint supports it.**

When in doubt, pick **OpenAI Compatible**. Switch later if needed.
:::

### Full Walkthrough

Below uses OpenAI official as the example. Every other vendor follows the same flow — only the values you type in steps 4–6 change.

**Step 1: Open the provider list**

```
Chat → tap "Settings" in the bottom tab bar
→ under "Conversation" → "Providers & Models"
→ tap to enter
```

You see an empty (or near-empty) list titled **Providers & Models**.

**Step 2: Add a new provider**

Tap **+ Add Provider** in the top-right (plus icon).

The **Add Provider** form opens, divided into four sections: Basic Info, Authentication, Proxy (per provider), Header Overrides.

**Step 3: Fill in "Basic Info"**

| Field | What to put |
| --- | --- |
| Provider Name | Your **display name**. Shown in the model picker. e.g. "OpenAI Official", "My Relay", "Claude". |
| API URL | Paste the Base URL from the cheat sheet above. **No trailing slash**, and **don't append** `/chat/completions`. |
| API Format | Pick from the dropdown. OpenAI official defaults to "OpenAI Compatible". |

::: warning Easy-to-miss Details
- No trailing slash (`/v1`, not `/v1/`)
- Don't forget `https://`
- If the relay docs give `https://xxx.com/v1/`, strip the trailing `/`
:::

**Step 4: Fill in "Authentication"**

| Field | What to put |
| --- | --- |
| API Key | Paste the key from the vendor console. **Just the key**, no `Bearer ` prefix, no quotes. |
| Show Plaintext | Toggle. Turns on to reveal the key so you can double-check the paste. Turn it off after. |

::: tip Multiple Keys per Provider
Want to rotate among several keys (to dodge per-key rate limits)? Concatenate them with **English commas**: `sk-aaa,sk-bbb,sk-ccc`. The app rotates through them in order on each request.
:::

**Step 5: Skip "Proxy (per provider)"**

Leave **Use Per-Provider Proxy (overrides global)** off if your network can reach the vendor directly. Set up proxies after chat is working.

**Step 6: Skip "Header Overrides"**

Don't touch this on your first pass. It's for relays that demand custom HTTP headers (e.g. `X-Org-ID`).

**Step 7: Save**

Tap **Save** in the top-right. If anything's missing (Base URL empty, etc.), the Save button grays out and the form highlights what's wrong.

After saving you bounce back to the provider list with your new entry visible.

**Step 8: Open the provider and add models**

Tap the new provider row to enter **Provider Details**. The bottom of the page shows an empty **Models** section.

Two ways to add models:

1. **Fetch from cloud** — the cloud icon in the top-right (accessibility label: "Fetch from cloud"). Sends `GET /models` to the vendor and pulls back every model your key can use. **Prefer this** — saves time and avoids ID typos.
2. **Add manually** — the `+` button beside it (label: "Add Model"). Type the model ID (`gpt-4o-mini`) and an optional display name. Useful if the vendor has no `/models` endpoint.

Once models are listed, **toggle on the row's switch**. Models that aren't enabled won't show up in the chat picker.

**Step 9: Run the connectivity test**

There's a test button in the top-right of the provider details page (accessibility label: "Model Test"). It fires a minimal request with your key and reports back. Use it — you don't have to bounce back to chat just to verify.

Results are binary:

- ✅ **Green "Test Passed"** — good, move on.
- ❌ **Red error** — match the message against the table below.

**Step 10: Set this model as "Current Model"**

Back in **Settings**, the top **Current Model** section → tap **Model** → pick the model you just enabled.

Now you're truly done. Head to [Start Your First Chat](/en/guide/first-chat) to send a message.

### Common Errors

| Error | Real Cause | Fix |
| --- | --- | --- |
| `401 Unauthorized` / "Authentication failed" | Key is wrong / expired / has trailing whitespace | Re-copy from the vendor console; strip whitespace |
| `404 Not Found` | Base URL wrong, or path appended/missing | Re-check the cheat sheet |
| "Model not found" / `model not found` | Wrong model ID, or key doesn't have access | Use "Fetch from cloud" and pick from the list |
| "Connection timeout" / "Network error" | Can't reach the vendor / proxy needed | Set up the per-provider proxy below |
| `429 Too Many Requests` | Vendor rate limit triggered | Wait a few minutes; or upgrade your account quota |

## Advanced

Everything below assumes basic chat already works.

### Custom Headers (Header Overrides)

Some relays or enterprise endpoints require extra HTTP headers, like `X-Org-ID` or non-standard `Authorization` formats.

**Where**: Edit Provider → Header Overrides → tap **Add Expression**.

**Syntax**: one entry per line, `key=value`:

```
User-Agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)
X-Org-ID=org_abc123
Authorization=Bearer {api_key}
```

**The `{api_key}` placeholder** is substituted with the API key actually used for that request (if you set up key rotation, it becomes the rotated key). Useful for services that demand the key in a custom header instead of the standard `Authorization`.

### Per-Provider Proxy

If you can't reach the vendor directly, configure a proxy for this provider:

**Where**: Edit Provider → Proxy (per provider) → toggle on **Use Per-Provider Proxy (overrides global)**.

| Field | Notes |
| --- | --- |
| Enable Proxy | Master switch for this proxy config |
| Proxy Type | **HTTP / HTTPS** or **SOCKS5** |
| Proxy Host | Hostname or IP, e.g. `127.0.0.1` |
| Port | 1–65535. Typical: HTTP proxy 8080 / 7890; SOCKS5 1080 |
| Username (optional) | Proxy auth username; setting it enables auth |
| Password (optional) | Proxy auth password |

::: tip Global vs Per-Provider Proxy
ETOS also has a **Global Proxy** (Settings → Providers & Models → Global Proxy). The per-provider proxy **wins** — when a provider's "Use Per-Provider Proxy" is on, the global proxy is ignored.

Useful when provider A needs a proxy but provider B works directly: only give A a proxy, leave B alone.
:::

### Multi-Key Rotation

The Authentication → API Key field accepts comma-separated keys:

```
sk-aaaaaaaaaa,sk-bbbbbbbbbb,sk-cccccccccc
```

Each request rotates through them in order. If a key trips 429 or auth fails, the next one is used.

### Different Capabilities → Different Models

ETOS slots models by capability. A single provider can host GPT-4o as the chat model, `whisper-1` as speech-to-text, and `tts-1` as the TTS model without conflict.

**Where**: under Settings → "Conversation" group, **Preferences** / **Text-to-Speech (TTS)** / **Speech Input** / **Image Generation** / **Daily Pulse** each have their own "preferred model" picker.

### Model-Level Advanced Parameters (Parameter Expressions / Raw JSON Body)

Inside Providers & Models, tap a specific **model row** to enter **Model Settings**. There you can:

- Override default sampling parameters (temperature, top_p, …) per model
- Write **parameter expressions** — a template syntax that computes parameter values dynamically (e.g. scale `max_tokens` with message length)
- Edit the **raw JSON body** sent in the request — last-mile customization for non-standard endpoints

Details in [Chat & Models](/en/modules/chat-and-models) advanced section.

## Next

Provider set up, connectivity test green, current model selected → [Start Your First Chat](/en/guide/first-chat)
