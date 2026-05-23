---
title: Start Your First Chat
description: With your provider set up, this page walks you through sending your first message and points out every button, switch, and panel along the way.
---

# Start Your First Chat

Once a provider is configured, sending the first message is just one tap. But the chat screen hides a lot of optional power: **attachments, tool switches, thinking toggles, model switching, session search, export**. This page gets the minimum loop working, then tells you what each control does and where to find it.

## Read This First

### Send Your First Message

Tap the **Chat** tab. If you've followed along, the screen should show:

- **Top bar**: hamburger icon **top-left** (opens the session list) / center shows **"New Conversation"** / top-right may show model controls
- A big empty middle area (the chat surface)
- **Bottom**: input field with placeholder `Message`, a **plus button** on the left (attachments), and a **send button** on the right

::: warning If the title says "Select a model to start"
You haven't picked a **Current Model**. Go back to **Settings → Current Model → Model** and choose one.
:::

**Easiest first message**: type "Hello", tap send.

If everything is wired up:

1. Your message appears as a bubble on the right.
2. An AI bubble appears on the left, with text streaming in word by word.
3. After streaming finishes, small metrics (duration, token count) may appear under the bubble depending on your settings.

**When you see the streaming reply, you're done.**

### When It Doesn't Work

Check in this order:

| Symptom | Real Cause | Fix |
| --- | --- | --- |
| Title says "Select a model to start" | No Current Model | Settings → Current Model → Model |
| Send button is grayed out | Empty input / no model | Check both |
| Alert "Authentication failed" | API key wrong or expired | Go back to [Add Your First Provider](/en/guide/first-provider) and verify |
| Alert "Connection failed" / timeout | Network can't reach the vendor | Enable per-provider proxy; or change network |
| Alert "Model not found" | Model ID wrong, or key lacks access | Use **Fetch from cloud** to re-pull the model list |
| Reply gets cut off mid-stream | Vendor rate limit / context overflow | Wait and retry; or lower **Max History Messages** in Preferences |

### What's Around the Input Bar

From left to right, top to bottom:

| Element | Looks Like | Does |
| --- | --- | --- |
| Plus (attachments) | `+` to the left of the field | Opens the attachment menu: photo, camera, voice, file |
| Input field | Rounded rect, placeholder `Message` | Type here. **Multi-line supported** — Return adds a new line, not send |
| Tool switches | A row of small icons above/below the field | Temporarily toggle tools for the next turn (see below) |
| Send button | Blue circular arrow on the right | Tap to send. Long-press for send-with-options (Advanced) |

#### What's in the Plus Menu

The bottom sheet (`ChatViewTelegramComposer`) lists five options:

| Option | System Icon | Does |
| --- | --- | --- |
| Choose Photo | `photo` | Pick an image from your library as a multimodal input. Needs a vision-capable model. |
| Take Photo | `camera` | Trigger the system camera for a fresh shot. |
| Record Voice | `waveform` | Capture audio inline as an attachment. |
| Upload from Voice Memos | `music.note.list` | Pick from existing iOS Voice Memos. |
| Choose File | `doc` | Pick anything (PDF, TXT, JSON, …) from the Files app. |

::: warning Model Must Support It
- Image attachments need a **vision model** (GPT-4o, Claude 3.5 Sonnet, Gemini, …).
- Audio attachments need a model that **accepts audio** (GPT-4o Audio, Gemini, …).

When the model doesn't support the modality, the attachment is dropped and the AI never sees it.
:::

### Switch Models

Tap the model selector in the top-right of the chat to see every **enabled** model. The switch applies **only to the current conversation** — other sessions keep their own selection.

To set the default model for **new** conversations: **Settings → Current Model → Model**.

### See How the AI Thinks

For reasoning-capable models (GPT-5, Claude 4, DeepSeek R1, Gemini Thinking, …), a collapsible gray **"Thinking"** panel appears inside the AI bubble while the model reasons. It's the live draft of the model's reasoning.

- Auto-expand: **Settings → Display & Experience → Visuals → Auto-Preview Thinking**, toggle on
- Hide it: collapse the panel manually

### Read Replies Out Loud

Long-press any AI bubble → **Read Aloud**. First time, configure a TTS model:

```
Settings → Conversation → Text-to-Speech (TTS) → pick a TTS model
```

Available TTS models come from your providers (OpenAI's `tts-1` / `tts-1-hd`, or any OpenAI-compatible TTS endpoint).

### Export the Whole Session or Just a Snippet

Every message's long-press menu has two export options:

| Option | Does | When to use |
| --- | --- | --- |
| Export Entire Session | Saves the full conversation | Archiving |
| Export Up to This Message (with context) | Saves everything up to (and including) this message | Sharing a snippet, or trimming context |

Formats: **PDF / Markdown / TXT**. The share sheet hands them to Files or your favorite app.

## Advanced

### Tool Switches (Per-Turn)

The row of tool icons around the input field maps to:

- **Web search** (if the model supports it)
- **MCP tools** (if you've connected an MCP server)
- **Skills** (if you've imported any Agent Skill)
- **Shortcuts** (if you've bound any iOS Shortcuts)

These toggles affect **only the next send**. To enable/disable a tool category globally, use its full Settings entry: Tool Center, MCP Tool Integration, Agent Skills, Shortcut Tool Integration.

### Multimodal: Send Images, Audio, Files

Flow:

1. Tap `+` → pick an attachment type.
2. A thumbnail (image) / waveform (audio) / file card appears above the input field.
3. To remove one, tap the `×` on its corner.
4. **You can still type** — text and attachments are sent together.
5. Tap send.

**Multi-image**: tap `+` → **Choose Photo** again — the picker supports multi-select.

### Branching

To explore an alternate timeline from any past message, long-press it → **Create Prompt Branch**. A "Branch Options" dialog asks:

- **Prompt only** — copy the system prompt without messages
- **Messages only** — copy everything up to (and including) the selected message, including AI replies

The branch becomes an **independent session**; the original is untouched.

### Search the Session List

Tap the hamburger to open the session list. The search field at the top (placeholder "Search session titles or messages") matches:

- **Title fuzzy match**
- **Full-text message content** — finds keywords inside any past message

Tapping a result jumps directly to the matching message ("message anchor").

### Organize Sessions with Folders

Long-press a session → **Move to Folder**. Create folders from the session-list header. A session can live in one folder at a time; you can reorganize whenever.

### History Window (Context Length)

The model only sees the most recent N turns, not your full history. Adjust it in:

```
Settings → Conversation → Preferences → Max History Messages
```

The default is balanced. **Lower** saves tokens but the AI forgets faster; **higher** lets the AI remember more but each request costs more.

### When Nothing Else Works

- **Verify the request actually went out**: Settings → Extended Features → Debug shows the full outgoing URL, headers, and body.
- **Temporarily switch providers**: if one provider misbehaves, switch to another in Settings and retry.
- **Reset the conversation**: long-press the session → Delete, then start a fresh one.

## Next

Chat is working → continue with the [Interface Tour](/en/guide/interface-tour) for a full map of the Settings page.

Or jump to whatever interests you:

- [Chat & Models](/en/modules/chat-and-models)
- [Tools & MCP](/en/modules/tools-and-mcp)
- [Memory & Worldbook](/en/modules/memory-worldbook)
- [Daily Pulse](/en/modules/daily-pulse)
