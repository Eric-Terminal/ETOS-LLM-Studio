---
title: Debug & Feedback
description: When an AI response misfires, a request fails, or you want to file feedback — this page covers local debug, app logs, traffic analysis, and the feedback system.
---

# Debug & Feedback

ETOS LLM Studio puts more thought into "how do I figure out what went wrong" than most LLM clients. It includes a **LAN debug client**, **app log archive**, **API traffic analysis**, and a **PoW-protected ticketed feedback system**. This page covers what each is and when to reach for it.

## Problems You're Likely to Hit

| Symptom | Reach for |
| --- | --- |
| AI reply didn't appear, error popup | **App Logs** for the exact error code |
| AI reply is nonsense | **API Traffic Analysis** to see the actual request and response |
| Want to file a bug | **Feedback Helper** |
| Want a computer to capture full request traces | **LAN Debug** |
| Want to inject a custom proxy / man-in-the-middle | **Local Debug Server Proxy** |

## Read This First

### App Logs (most-used)

#### Where

```
Settings → Extended Capabilities → Extended Features → App Logs
```

Or tap "View Logs" from an error popup.

#### What It Records

Daily folders named by date contain structured (JSON) logs of every request and response:

- Each LLM request's full URL, headers, body
- Each response (including streaming chunks)
- Tool call requests and returns
- Failure error codes / stack traces

#### "Record Plaintext Request Messages"

| State | Behavior |
| --- | --- |
| Off (default) | Request body logs **redact** `message`, `content`, etc. (structure visible, content hidden) |
| On | Records plaintext messages, but **image, audio, and file Base64 stays redacted** (avoids log explosion) |

::: warning Plaintext Logs Contain Sensitive Content
Turning on plaintext logging means **everything you chat about lands on disk**. If you don't want that record kept, leave it **off** and only flip it on during active debugging.
:::

#### How to Use

1. Reproduce the problem
2. Open App Logs, find today's folder
3. Locate the entry by timestamp
4. Read the error details

#### Cleanup

- Single day: **Swipe to Delete**
- **"Clear All"** wipes history (with confirmation)

### Feedback System

#### Where

```
Settings → Extended Capabilities → Extended Features → Feedback Helper
```

Or "Send Feedback" from certain error popups.

#### Filing Feedback

Each ticket includes:

- **Type**: Bug / Feature Request / Question / Other
- **Title** + **Body**
- **Environment info** (auto-captured): version, iOS version, device model, simulator status
- **Screenshots** (optional)
- **Log attachment** (optional): a redacted log zip

#### PoW Anti-Spam

Submission requires a **Proof of Work** — your device spends a few CPU seconds on a hash challenge. This is ETOS's spam guard: no email verification, but every ticket pays a small CPU cost.

#### Ticket Lifecycle

Submitted tickets get a number. The feedback list shows:

- **Status**: Unread / Read by Developer / In Progress / Resolved / Closed
- **Comment thread**: developers reply on the ticket; you reply back
- **Developer flags**: "Confirmed Bug", "Cannot Reproduce", "Fixed in Next Version", etc.

State **auto-syncs**.

#### Two-way Tickets

- iPhone tickets sync to the Watch
- System notifications push status updates

### API Traffic Analysis

#### Where

```
Settings → Extended Capabilities → Extended Features → Advanced Diagnostics
```

#### Simple Mode (token usage only)

For just token usage and response speed, [Usage Analytics](/en/modules/chat-and-models) is enough.

#### Full Traffic Capture

**Advanced Diagnostics** captures the **complete flow** per request:

- Full URL (including query string)
- Full request headers (including Authorization)
- Full request body
- Full response headers
- Full response body (streaming-merged)

Best for figuring out "why did the AI say what it said."

## Advanced

### LAN Debug Mode

Top of Advanced Diagnostics, **Connection Mode**: choose **HTTP Polling** or **WebSocket**.

Use with the **PC-side debug tools** in `docs/debug-tools` and `docs/debug-tools-go`.

#### How It Works

> The device proactively connects to the PC-side WebSocket server, receives commands, and executes file operations.

The device **dials out** — no need to open router ports. The PC runs a WebSocket server (default port 8765); the device connects and lets you:

- Browse the app's sandbox files
- Pull the local database for diagnostics
- Upload / download files
- Watch a live console in a browser

#### Steps

1. PC: run the server in `docs/debug-tools/` (npm project)
2. PC server prints its **local IP + port** when started
3. iPhone: Advanced Diagnostics → enter "IP:port" (e.g. `192.168.1.100:8765`) → tap **Connect**
4. When green, watch the live log in your browser

::: warning Only on Trusted Networks
Advanced Diagnostics **fully exposes the app sandbox** to the PC. Don't use it on coffee-shop Wi-Fi or any public network.

The on-page warnings:
> Use only on trusted networks
> Disconnect promptly after use
:::

#### API Proxy Mode

The **API Proxy Settings** option routes all LLM requests through the PC-side man-in-the-middle:

```
Set API Base URL to: http://PC-IP:8080
```

Requests get logged, parsed, optionally modified, then forwarded to the real LLM API. Good for:

- Inspecting full streaming response content
- Writing your own middleware to alter requests / responses
- Mocking error responses to test app behavior

### Global Proxy (Production Networks)

```
Settings → Providers & Models → Global Proxy
```

If **every** LLM request needs a proxy:

| Field | Notes |
| --- | --- |
| Enable Proxy | Master switch |
| Proxy Type | HTTP / HTTPS / SOCKS5 |
| Proxy Host | Hostname or IP |
| Port | 1–65535 |
| Username (optional) | Proxy auth |
| Password (optional) | Proxy auth |

**Priority** (covered in [Add Your First Provider](/en/guide/first-provider) advanced): per-provider proxy > global proxy.

Best for:

- Network-wide proxy requirement (corporate, VPN)
- You don't want to configure each provider separately

### Log Redaction Behavior

ETOS redacts by default:

| Field | Recorded |
| --- | --- |
| URL | ✅ Full |
| Headers | ✅ Full (Authorization included — **for debugging**; redact before sharing) |
| Body `messages` text | ❌ Hidden by default (turn on "Record Plaintext Messages" to include) |
| Body image base64 | ❌ Always hidden |
| Body audio base64 | ❌ Always hidden |
| Body file base64 | ❌ Always hidden |
| Streaming response body | ✅ Recorded merged |

::: tip Redact Again Before Sharing
Even with built-in redaction, logs still contain URLs and headers that may include API keys. **Before sharing** with a developer, do another pass: replace `Authorization` / `X-API-Key` etc. with `***`.
:::

## Next

- Everyday small tricks → [Hidden Gems](/en/tips/hidden-gems)
- What the Watch can do → [Using Apple Watch](/en/tips/watch-usage)
- Stuck on a specific issue → [FAQ](/en/faq/)
