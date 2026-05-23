---
title: Sync & Backup
description: Two-way iPhone ↔ Apple Watch sync; snapshots, ETOS bundles, S3 / R2 upload, and third-party import for every migration and recovery scenario.
---

# Sync & Backup

ETOS stores everything in a local SQLite database. That means:

- **Great for privacy** — nothing leaves the device by default
- **Risk** — phone lost / wiped / app uninstalled = **all data gone**

This page covers how to **prevent that**: two-way sync, multiple backup paths, cross-app import.

## What This Page Covers

| Topic | Solves |
| --- | --- |
| **iPhone ↔ Watch Sync** | Real-time two-way device data |
| **iCloud Sync** | Multi-iPhone roaming, second-iPhone takeover |
| **Snapshot Backup** | DB corruption rollback; device migration |
| **S3 / R2 Upload** | Long-term object storage of backups |
| **Third-party Import** | Migrate from other LLM clients |

## Read This First

### Where

```
Settings → Display & Experience → Sync & Backup
```

Key sections inside:

- Database Protection (manual snapshots)
- Apple Watch Sync
- iCloud Sync
- iCloud Status

### Apple Watch Sync

#### Turn It On

Enable **"Enable Apple Watch Sync"**. The footer explains:

> When on, the iPhone and Apple Watch fully roam supported data; when off, near-field sync inbound data is rejected.

It uses **LAN direct connection** — as long as iPhone and Watch are on the same Wi-Fi (or within Bluetooth range), they sync directly, with **no external server**.

#### What Syncs

| Data type | Synced? |
| --- | --- |
| Sessions and messages | ✅ |
| Provider configs (incl. API keys) | ✅ |
| Enabled models | ✅ |
| Memories | ✅ |
| Worldbooks | ✅ |
| MCP server configs | ✅ |
| Daily Pulse history | ✅ |
| Wallpapers / custom fonts | ⚪ Depends on device capability |
| Tool call traces | ❌ Not synced (data volume too high) |

#### Manual Sync

Normally both ends stay in lockstep. If something didn't propagate, the "Apple Watch Sync" section has a **Sync** button to trigger one manually.

#### Sync Status

The **Apple Watch Status** section shows:

- ✅ **Sync Success** with last sync time
- ❌ **Sync Failed** with error
- ⚪ **No Sync Yet**

### iCloud Sync

**Different from Apple Watch sync — they're two independent mechanisms**:

| Dimension | Apple Watch Sync | iCloud Sync |
| --- | --- | --- |
| Purpose | iPhone ↔ Watch data flow | Multi-iPhone roaming / disaster recovery |
| Transport | LAN direct | Apple iCloud Drive |
| Frequency | Real-time on every change | Background periodic |
| Best for | Same person, multiple devices | Switching iPhones / second iPhone |

#### Turn It On

**"Enable iCloud Sync"** lets you manually **"Sync to iCloud"**.

> Used for roaming data across multiple devices under the same Apple ID. Leave off if only one device uses the app; turning it on uploads a snapshot of this device and merges with snapshots from other devices, **including provider API keys synced across your devices**.

::: warning API Keys Roam Too
Turning on iCloud sync means your LLM API keys also **encrypt and upload to your iCloud**. Apple can't see them, but make sure your Apple ID has **two-factor authentication**.
:::

### Snapshot Backups (Most Important)

The **Database Snapshot** button (cloud-up arrow) opens the full snapshot backup / restore page.

#### Two Snapshot Types

| Type | Includes | Size |
| --- | --- | --- |
| **Database Snapshot** | Chat, config, memory DBs | Small (a few MB) |
| **Full Snapshot** | DBs + wallpapers + audio + image + file attachments + custom fonts + memory vector index | Large (depends on attachments) |

Default to **Full Snapshot**. Database Snapshot if storage is tight.

#### Encryption

**"Set Password"** encrypts the snapshot. Adding **"Strong Derivation"** uses PBKDF2-HMAC-SHA512 with 256,000 iterations — slower (a few seconds extra) but more secure.

::: danger Lost Password = Lost Backup
ETOS doesn't store your password. **Forgetting it means the backup is permanently unrecoverable.** Use a password manager.
:::

#### "Create iCloud Drive Snapshot"

Writes the snapshot to iCloud Drive's **ETOS LLM Studio Backups** folder:

> The snapshot is written to iCloud Drive's "ETOS LLM Studio Backups" folder; if iCloud Documents capability isn't enabled, the system writes to the local Documents/ folder with the same name.

Files have the `.elsbackup` extension.

#### Restore

Bottom of the page, **"Restore from Snapshot"** → pick a `.elsbackup` file → enter password (if any).

> Restore replaces the current chat, config, and memory databases; a full snapshot also restores wallpapers, attachments, fonts, and the memory vector index file. **Choose a trusted `.elsbackup` file.**

After restore: "Snapshot restored. If the current screen still shows old data, return to the session list and re-enter."

#### Launch Backup Point

**"Create Database Backup on Launch"** dumps a recoverable backup to disk on every app launch.

> Manual snapshots are for cross-device disaster recovery; launch backups protect against SQLite database corruption.

Cheap insurance — lets you roll back to the last launch state if something breaks.

### Import from Another Client

Settings → Display & Experience → Sync & Backup → **Third-Party Import** (or the entry inside the snapshot page).

Pick a **Source**:

| Source | Format |
| --- | --- |
| **Cherry Studio** | Full `backup.zip` |
| **RikkaHub** | Exported JSON |
| **Kelivo** | Exported JSON |
| **ChatGPT Official** | `conversations.json` |
| **ETOS** | `.elsbackup` or ETOS bundle |

After choosing, tap **"Select File and Parse"** to pick the file in Files.

After parsing you'll see an **import summary**: how many providers, sessions, memories, MCPs, Skills, worldbooks will be added.

Confirm to write to the database.

::: tip Back Up First Before Bulk Imports
If you've been using ETOS already and want to import a large batch, **take a full snapshot first**. If the import pollutes the database, you can restore with one tap.
:::

## Advanced

### Upload to S3 / R2 / Any Compatible Object Store

The snapshot page's bottom **"S3-Compatible Object Storage"** section uploads snapshots to external object storage:

| Field | Value |
| --- | --- |
| Endpoint | `https://<account>.r2.cloudflarestorage.com` (R2) or AWS S3 endpoint |
| Region | `auto` (R2) or `us-east-1` (AWS) etc. |
| Bucket | Bucket name |
| Backup Key Prefix (optional) | Prefix, e.g. `etos/iphone-15-pro/` |
| Access Key ID | Generated from your S3/R2 console |
| Secret Access Key | Same |
| Session Token (optional) | Only for temporary credentials |

**"Upload to S3/R2"** uses AWS Signature V4 to PUT the `.elsbackup` to `bucket/prefix/filename`.

Best for:

- Weekly full snapshots stored in the cloud long-term
- Multi-device shared backup repo
- Using cheap R2 / B2 / Wasabi instead of iCloud Drive

### Database vs Full Snapshot — Which to Pick

| Situation | Pick |
| --- | --- |
| Regular backup | Database (small, fast) |
| Switching phones | Full (with attachments, fonts) |
| Debugging / sharing with developer | Database (redact and share) |
| Storage-tight (iCloud 200GB full) | Database + manage attachments separately |

### Cross-Phone Watch Takeover

Watch data depends on the iPhone for sync. **To move the Watch to a new iPhone**:

1. Install ETOS LLM Studio on the new iPhone
2. Full snapshot on old phone → AirDrop or iCloud to new phone
3. Restore snapshot on new phone
4. Pair Watch to new phone (system pairing, not ETOS)
5. Enable Apple Watch sync in ETOS settings → data auto-flows over

### Sync Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Watch shows "Not Synced" | Bluetooth off / different Wi-Fi | Check connection; manual Sync |
| Sync failed | Data format incompatibility | Check error log; file feedback |
| iCloud stuck spinning | iCloud Drive network issue | System Settings → check iCloud status |
| Cross-device data conflict | Both ends edited simultaneously | Last write wins. **Configure on iPhone only**, use Watch to read |

### Launch Backup Physical Location

Launch backups live in the app sandbox. They **do not** auto-sync to iCloud or cloud.

For long-term retention you must **periodically take full snapshots** to iCloud Drive or S3.

## Next

- What the Watch can do → [Using Apple Watch](/en/tips/watch-usage)
- Local debugging → [Debug & Feedback](/en/modules/debug-feedback)
