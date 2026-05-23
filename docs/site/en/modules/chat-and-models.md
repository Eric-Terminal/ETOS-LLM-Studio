---
title: Chat & Models
description: Treat ETOS LLM Studio as a long-term model workstation — session management, multimodal, parameter tuning, reading experience, and visuals all in one page.
---

# Chat & Models

ETOS LLM Studio's edge isn't "you can send messages" — every LLM client does that. Its value is in **how sessions become long-term assets**, **how tunable the parameters are**, and **how comfortable long AI responses are to read**. This page covers all three.

For the actual order in which a message's context gets assembled, see [Prompt & Context Assembly](/en/design/prompt-assembly).

## Read This First

### Session Management as a Long-term Asset

A "session" is a continuous chain of messages. But ETOS treats them as assets you can categorize, search, share across devices, and branch — not just a transcript.

#### The Session List (top-left menu)

Tapping the menu on the chat screen opens the full session list:

- **Search field** with placeholder "Search session titles or messages" — does **full-text message search**, not just titles. Tapping a result jumps to the matching message.
- **New conversation** button
- **Folders** — group sessions by topic. Long-press a session → Move to Folder.
- **Session entries** — each shows title (auto-named or manually renamed) plus a preview of the last message.

#### What Long-press on a Message Does

Almost every per-message action lives in the long-press menu:

| Action | Use |
| --- | --- |
| Copy | Copy message text |
| Quote | Quote this message in your next input |
| Edit | Rewrite either your input or the AI's reply |
| Delete | Remove this single message |
| Token Info | See prompt / completion / thinking tokens |
| Thinking Duration | Reasoning models only — how long the AI thought |
| Export Entire Session | Save the whole conversation |
| Export Up to This Message | Save up to (and including) this one |
| Create Prompt Branch | Spin off a new session from here (see below) |

#### Branching

Long-press → **Create Prompt Branch** opens a "Branch Options" dialog with two choices:

- **Prompt only** — clone the system prompt, no messages
- **Messages only** — clone everything up to here (including AI replies)

The branch is a **completely independent session**; the original is untouched. Use it for:

- "Try the same question with a different tone"
- "Diverge here without polluting the main thread"
- "Use this thread as a template for a fresh start"

### Multiple Providers and Models

ETOS supports four API formats (not just four vendors — one format covers countless vendors):

| API Format | Internal ID | Who uses it |
| --- | --- | --- |
| OpenAI Compatible (Chat Completions) | `openai-compatible` | Official OpenAI legacy + nearly every third-party relay + China-based compatible services |
| OpenAI Responses | `openai-responses` | OpenAI's newer endpoint for GPT-4.1 / GPT-5 |
| Anthropic | `anthropic` | Claude official |
| Gemini | `gemini` | Google official |

**Key concepts**:

- A provider has **one** API format — pick Anthropic when adding Claude.
- A provider can host **many** models — the same OpenAI key works for GPT-4o, GPT-4o-mini, `text-embedding-3-large`, `whisper-1`, `tts-1` simultaneously.
- Models are slotted by **capability**: chat / image / embedding / rerank / speech-to-text / text-to-speech. A model can have multiple capabilities.

#### Assigning Models by Capability

In **Settings → Providers & Models → Preferred Models**, pick a specific model for each capability:

| Slot | Used for | Typical pick |
| --- | --- | --- |
| Chat Model | Default conversation | GPT-4o / Claude 3.5 Sonnet / Gemini 2.5 Pro |
| Embedding Model | Memory system retrieval vectors | `text-embedding-3-large` |
| TTS Model | Read AI replies aloud | OpenAI `tts-1` |
| Speech-to-Text | Voice input | `whisper-1` |
| Image Generation | Configured separately in Image Generation | `gpt-image-1` / Gemini Imagen / DALL·E |
| Daily Pulse Model | Daily Pulse generation | Pick something cost-effective |

These are all **independent** — you can run chat on GPT-4o, STT on Whisper, and Daily Pulse on Claude.

### Multimodal: Images, Voice, Files

"Multimodal" means the AI handles more than text. **Prerequisite**: the model you choose must support that modality.

#### Image Input

- From library: chat → `+` → **Choose Photo**, multi-select supported
- From camera: `+` → **Take Photo**
- Supported: JPG / PNG / HEIC / WebP (auto-transcoded)
- Compatible models: GPT-4o, Claude 3.5/4, Gemini 1.5/2.5

#### Voice Input (two modes)

Configure under **Settings → Speech Input**. Once enabled, a mic button appears near the input.

Two delivery modes:

| Mode | Behavior | Compatible models |
| --- | --- | --- |
| Transcribe first | STT model (Whisper, etc.) converts to text before sending | Any chat model |
| Send as audio attachment | Audio file goes to the AI for direct listening | GPT-4o Audio / Gemini / any model with native audio input |

#### File Attachments

`+` → **Choose File** sends any file from the Files app. Note:

- Text-based (TXT, Markdown, JSON, Swift, Python, …) — content gets read out and added to context
- PDF — text extraction is attempted
- Binary — sent as-is with a warning that the model may not parse it

### TTS — Read AI Aloud

**First time**:

```
Settings → Conversation → Text-to-Speech (TTS) → pick a TTS model
```

The TTS model must be a TTS-capable model you've added under some provider (`tts-1`, `tts-1-hd`, etc.).

**Usage**:

- Long-press any AI bubble → **Read Aloud**
- Or auto-play when a reply finishes (toggle in settings)
- A floating control appears during playback (pause / stop / speed)

::: tip Does TTS Work Offline?
No — TTS hits the model's API, so it needs the network. Streaming makes it feel as smooth as system TTS.

If you want pure offline, the **Extended Features** section has a toggle to use iOS's built-in `AVSpeechSynthesizer` instead, but the voice quality is lower.
:::

### Reading Experience: Long AI Output as a Readable Document

ETOS's rendering layer is more than vanilla Markdown. By default:

#### Markdown Enhancements (Settings → Display & Experience → Backgrounds & Visuals)

| Toggle | Default | Effect |
| --- | --- | --- |
| Enable Markdown | On | Off shows raw text everywhere |
| Enable Advanced Renderer | On | Code highlighting, math formulas, Mermaid |
| Auto-Preview Thinking | Off | Reasoning model thinking panel auto-expands |
| Enable Liquid Glass | On | iOS 26 Liquid Glass effect |
| Top Blur Fade | On | Soft top edge when scrolling |

#### Code Block Features

- **Syntax highlighting** for 100+ languages
- **Copy button** in the corner with feedback animation
- **iOS code preview** — long-press a Swift/SwiftUI block to launch iOS's native code preview with syntax tree
- **Collapse** — blocks longer than 50 lines auto-fold

#### Math / Mermaid

- LaTeX: `$inline$` and `$$display$$`
- Mermaid: ` ```mermaid ` fences auto-render

### Display System

#### Custom Fonts

**Settings → Display & Experience → Backgrounds & Visuals → Font Fallback**:

- Import custom font files (WOFF / WOFF2 / TTF / OTF)
- Slot priority (CJK font / Latin font / monospace)
- Fallback chain (which font to pick when a glyph is missing)

Use cases:

- Specific CJK font for mixed CJK-Latin text
- Screen-optimized fonts like [Sarasa Gothic SC](https://github.com/be5invis/Sarasa-Gothic) for long-form reading

#### Background and Bubbles

- Enable background image → upload → blur and opacity
- Auto-rotate background per new conversation or on a timer
- Hide assistant bubble — AI replies render directly on the background like a document

## Advanced

### Preferences (Global Default Parameters)

**Settings → Conversation → Preferences** controls:

| Field | Effect |
| --- | --- |
| Global System Prompt | Default system prompt for new sessions. Multiple named profiles supported. |
| AI Temperature | 0–2. Higher = more creative, lower = more deterministic. 0.7 is balanced. |
| AI Top-P | 0–1. Nucleus sampling alternative to temperature. Usually only tune one. |
| Enable Streaming | Off waits for full generation before showing. **Toggle off when debugging a finicky relay.** |
| Enable Response Speed Metrics | Show chars/sec, time-to-first-token per reply |
| OpenAI Stream Include Usage | Whether OpenAI-compatible streams should carry `usage`. Disable for relays that omit it. |
| Enable Auto Session Naming | Auto-name a session after the first reply |
| Enable Reasoning Summary | Reasoning models generate thinking summaries |
| Max History Messages | Upper bound on history sent to the model. See below. |
| Lazy Load Message Count | How many messages to load when opening a session |

#### Tuning "Max History Messages"

A consequential value:

- Low (≤10): saves tokens, AI forgets fast
- High (50+): AI remembers more, requests get expensive
- Recommended: **leave around 30 by default**, adjust to taste

#### Global System Prompts

A common pattern:

1. **Create multiple profiles**: "Default", "Code", "Translation", "Roleplay", …
2. **Independent content per profile**
3. **Switch per conversation** in the chat screen or when creating a new session

### System Time Injection

In Preferences, **Inject System Time** auto-includes the current system time in every request. Add **Periodic Time Landmark** to inject a fresh timestamp every N minutes inside the conversation, keeping the AI grounded in real time during long sessions.

### Model-Level Advanced Parameters

In **Settings → Providers & Models → \[a specific model\] → Model Settings** you can:

- Override defaults (temperature, top_p, max_tokens) per model
- Write **parameter expressions** — template syntax to compute parameters dynamically
- Edit the **raw JSON body** as last-mile customization

#### Parameter Expression Example

Conceptual, not a copy-paste recipe:

```
max_tokens = clamp(messages.last.content.length * 2, 512, 8192)
```

Means: scale `max_tokens` with the last message's length, clamped to [512, 8192].

#### Raw JSON Body

Some non-standard endpoints want extra fields in the body (e.g. some relays want `extra_body.thinking.budget_tokens = 32000` for Claude). This is the last hook. **Most users never need it** — only when "all standard fields look right but the endpoint rejects."

### Session Import/Export

ETOS doesn't lock data in.

**Import** (Settings → Sync & Backup → Third-Party Import):

- Cherry Studio full backup
- RikkaHub export
- Kelivo export
- ChatGPT official `conversations.json`
- ETOS bundles (full config)

**Export** (long-press a message in chat):

- PDF
- Markdown
- TXT

### Usage Analytics

**Settings → Extended Capabilities → Usage Analytics** breaks down token usage and spend by provider / model / date. Requires per-model pricing:

Settings → Providers & Models → \[model\] → **Pricing** — fill in `prompt` / `completion` rates from the vendor's pricing page. With pricing set, ETOS computes spend automatically.

## Next

- Give the AI tools → [Tools & MCP](/en/modules/tools-and-mcp)
- Let the AI remember things across sessions → [Memory & Worldbook](/en/modules/memory-worldbook)
- Get proactive briefings → [Daily Pulse](/en/modules/daily-pulse)
