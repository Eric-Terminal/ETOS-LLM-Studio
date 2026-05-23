---
title: Install & First Launch
description: Get ETOS LLM Studio onto your iPhone and Apple Watch, then run through the minimum post-launch checklist.
---

# Install & First Launch

ETOS LLM Studio is a **native** AI client for iPhone and Apple Watch. It isn't a webview wrapper or a chatbot frontend — chat, memory, worldbook, Daily Pulse, MCP tools, and sync all run locally on your devices. Model requests go directly from your phone or watch to the provider, **never through a middle server**.

This page gets the app onto your device and walks you through the bare-minimum checks so the rest of the tutorials work.

## Read This First

### What You Need

| Item | Requirement | Required? |
| --- | --- | --- |
| iPhone | iOS 17 or later | ✅ Yes |
| Apple Watch | watchOS 10 or later | ⚪ Optional — phone-only is fine |
| Apple ID | Any region | ✅ Yes |
| LLM API key | At least one | ✅ Yes |
| Network | Can reliably reach the provider you plan to use | ✅ Yes |

::: tip What's an API key?
An API key is a string (something like `sk-xxxxxxxxxxxxxxxx`) that LLM vendors — OpenAI, Anthropic, Google, etc. — issue to authorize your account. It tells the model "this request belongs to a paying/trial user, please answer." **Keys are not interchangeable across vendors** — an OpenAI key cannot call Anthropic.

If you don't have one yet, grab one from [OpenAI Platform](https://platform.openai.com/api-keys), [Anthropic Console](https://console.anthropic.com/), or [Google AI Studio](https://aistudio.google.com/apikey).
:::

### Install the App

ETOS LLM Studio is **not on the App Store yet**. You install it one of two ways:

**Option A: TestFlight (recommended)**

1. Install [TestFlight](https://apps.apple.com/app/testflight/id899247664) on your iPhone.
2. Open the TestFlight invite link from the project's [GitHub Releases](https://github.com/Eric-Terminal/ETOS-LLM-Studio/releases) page.
3. Accept and install when TestFlight prompts you.
4. The **ETOS LLM Studio** icon appears on your home screen when done.

**Option B: Build it yourself in Xcode (for developers)**

If you have Xcode 16 or later, clone the repo, open `ETOS LLM Studio.xcworkspace` (the **workspace**, not the `xcodeproj`), pick the `ETOS LLM Studio App` scheme, set your signing team, and Run on a real device. The Apple Watch App builds automatically as an embedded target.

::: warning Don't open the xcodeproj
The repo contains both `.xcodeproj` and `.xcworkspace`. Always open the **workspace**. The bare `xcodeproj` is missing the Swift Package config and fails to build.
:::

### Install on Apple Watch

Once the iPhone app is installed, the Watch app usually deploys to your paired Apple Watch automatically. **If it doesn't**:

1. Open the system "Watch" app on your iPhone (the dial icon).
2. Scroll to the "Available Apps" section near the bottom.
3. Find "ETOS LLM Studio" and tap "Install".

To verify, press the Digital Crown on the Watch to go to the home grid — you should see the ETOS LLM Studio icon.

### What You See on First Launch

There's **no onboarding flow** — this is a utility app, not a social product. You go straight to the main screen, with two tabs at the bottom:

- **Chat** (default): the current conversation window on top, the input area on the bottom. You'll see an empty "New Conversation" waiting for your first message.
- **Settings**: everything else — providers, models, tools, memory, worldbook, sync, appearance, Daily Pulse — lives here.

::: info Why such a sparse main screen?
ETOS LLM Studio packs all features into Settings and keeps the main screen for chat only. The trade-off is a longer Settings page; the benefit is no banners, promos, or "recommended" rails interrupting daily use.

For a layout-by-layout walkthrough of every Settings entry, see the [Interface Tour](/en/guide/interface-tour).
:::

### Three Things to Do Right After Launch

**Before anything else**, do these in order:

#### 1. Handle the Permission Prompts

iOS asks for several permissions the first time:

| Permission | What it's for | Recommended |
| --- | --- | --- |
| Local Network | LAN debugging / iPhone ↔ Watch discovery | Allow |
| Notifications | Daily Pulse delivery, generation-complete alerts | Allow |
| Microphone | Voice input, audio attachments | Allow (revoke later if unused) |

Missed one? You can change it later in iOS Settings → ETOS LLM Studio.

#### 2. Set Up at Least One Provider

Without a provider, the app **cannot chat at all**. This is the most important step. It has its own page: [Add Your First Provider](/en/guide/first-provider).

#### 3. After Setup, Come Back and Check "Current Model"

Return to Settings. The very first section, **Current Model**, should show the model you just enabled.

If it says **"No models available. Please enable one under Providers & Models."**, it means you added the provider but haven't toggled on a specific model for chat. Open **Settings → Providers & Models** and switch on the model you want to use.

## Advanced

### I Only Have an Apple Watch — No iPhone

The Watch app can hit model APIs on its own, but **we don't recommend going Watch-only**. Configuration (providers, worldbook, memory) is entered on the iPhone — the Watch screen is too small for forms.

If you really only have a Watch, the workaround is to borrow an iPhone, export an ETOS data bundle via **Settings → Sync & Backup**, and transfer it to your Watch through iCloud Drive. See [Sync & Backup](/en/modules/sync-backup) for details.

### Where Is Data Stored / How to Back Up

ETOS LLM Studio does **not** use any cloud account. Data is local by default:

- **iPhone**: SQLite database inside the app sandbox. Size shows up in iOS Settings → General → iPhone Storage → ETOS LLM Studio.
- **Apple Watch**: a mirrored copy synced over.
- **Cross-device**: ETOS data bundles via iCloud Drive, or direct LAN sync.

::: danger Uninstalling Deletes Data
Uninstalling the iPhone app **permanently destroys the local database** and there's no iCloud backup. Before uninstalling, export a full ETOS data bundle from **Settings → Sync & Backup → Export ETOS Bundle** and stash it somewhere safe (iCloud Drive, external drive, etc.).
:::

### Migrate From Another App

If you used Cherry Studio, RikkaHub, Kelivo, or exported from ChatGPT, you can feed those files straight into ETOS:

**Settings → Sync & Backup → Third-Party Import → pick format → pick file**

Supported formats:

- **Cherry Studio**: full `backup.zip`
- **RikkaHub**: exported JSON
- **Kelivo**: exported JSON
- **ChatGPT official export**: `conversations.json`

Conversations, provider configs, and model lists map into ETOS's schema as best as possible. Unrecognized fields are silently dropped — they won't pollute your database.

### Common Build Errors

- **`watchOS link error`**: stale `SDKROOT` (and friends) in your shell. Prefix builds with `env -u SDKROOT -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u OBJC_INCLUDE_PATH xcodebuild …`.
- **`Could not get trait set for device Watch7,18`**: a known Xcode toolchain warning during asset thinning. **Does not affect compilation.** Target `generic/platform=watchOS Simulator` to bypass it.
- **Signing failed**: make sure your Apple ID is added under Xcode → Settings → Accounts, and change the bundle identifier to your own reverse-domain string.

## Next

App installed → [Add Your First Provider](/en/guide/first-provider)
