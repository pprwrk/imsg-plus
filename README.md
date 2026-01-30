# 💬 imsg-plus — Enhanced iMessage CLI with Typing, Reactions & More

An enhanced macOS Messages.app CLI that adds typing indicators, read receipts, and tapback reactions to the original [imsg](https://github.com/steipete/imsg). Basic features use AppleScript; advanced features use IMCore via an Objective-C helper.

## Features

### Original Features
- List chats, view history, or stream new messages (`watch`).
- Send text and attachments via iMessage or SMS (AppleScript, no private APIs).
- Phone normalization to E.164 for reliable buddy lookup (`--region`, default US).
- Optional attachment metadata output (mime, name, path, missing flag).
- Filters: participants, start/end time, JSON output for tooling.
- Read-only DB access (`mode=ro`), no DB writes.
- Event-driven watch via filesystem events.

### 🆕 New imsg-plus Features
- **Typing indicators** — Show/hide typing bubble with `imsg typing`
- **Read receipts** — Mark messages as read with `imsg read`
- **Tapback reactions** — Send reactions (❤️ 👍 👎 😂 ‼️ ❓) with `imsg react`
- **Status check** — Verify feature availability with `imsg status`
- **Objective-C helper** — Bridges Swift to IMCore private framework

## Requirements
- macOS 14+ with Messages.app signed in.
- Full Disk Access for your terminal to read `~/Library/Messages/chat.db`.
- Automation permission for your terminal to control Messages.app (for sending).
- For SMS relay, enable “Text Message Forwarding” on your iPhone to this Mac.

## Install
```bash
make build
# Builds both Swift CLI and Objective-C helper
# Binaries at ./.build/release/imsg and ./.build/release/imsg-helper
```

## Commands

### Original Commands
- `imsg chats [--limit 20] [--json]` — list recent conversations.
- `imsg history --chat-id <id> [--limit 50] [--attachments] [--participants +15551234567,...] [--start 2025-01-01T00:00:00Z] [--end 2025-02-01T00:00:00Z] [--json]`
- `imsg watch [--chat-id <id>] [--since-rowid <n>] [--debounce 250ms] [--attachments] [--participants …] [--start …] [--end …] [--json]`
- `imsg send --to <handle> [--text "hi"] [--file /path/img.jpg] [--service imessage|sms|auto] [--region US]`

### New Commands (imsg-plus)
- `imsg typing --handle <phone/email> --state on|off` — Control typing indicator
- `imsg read --handle <phone/email> [--message-guid <guid>]` — Mark messages as read
- `imsg react --handle <phone/email> --guid <message-guid> --type <reaction> [--remove]` — Send tapback
- `imsg status` — Check if advanced features are available

### Quick samples
```
# list 5 chats
imsg chats --limit 5

# list chats as JSON
imsg chats --limit 5 --json

# last 10 messages in chat 1 with attachments
imsg history --chat-id 1 --limit 10 --attachments

# filter by date and emit JSON
imsg history --chat-id 1 --start 2025-01-01T00:00:00Z --json

# live stream a chat
imsg watch --chat-id 1 --attachments --debounce 250ms

# send a picture
imsg send --to "+14155551212" --text "hi" --file ~/Desktop/pic.jpg --service imessage

# NEW: show typing indicator
imsg typing --handle "+14155551212" --state on

# NEW: mark messages as read
imsg read --handle "+14155551212"

# NEW: send a tapback reaction
imsg react --handle "+14155551212" --guid "ABC-123" --type love

# NEW: check feature availability
imsg status
```

## Attachment notes
`--attachments` prints per-attachment lines with name, MIME, missing flag, and resolved path (tilde expanded). Only metadata is shown; files aren’t copied.

## JSON output
`imsg chats --json` emits one JSON object per chat with fields: `id`, `name`, `identifier`, `service`, `last_message_at`.
`imsg history --json` and `imsg watch --json` emit one JSON object per message with fields: `id`, `chat_id`, `guid`, `reply_to_guid`, `sender`, `is_from_me`, `text`, `created_at`, `attachments` (array of metadata with `filename`, `transfer_name`, `uti`, `mime_type`, `total_bytes`, `is_sticker`, `original_path`, `missing`), `reactions`.

Note: `reply_to_guid` and `reactions` are read-only metadata.

## Permissions troubleshooting
If you see "unable to open database file" or empty output:
1) Grant Full Disk Access: System Settings → Privacy & Security → Full Disk Access → add your terminal.
2) Ensure Messages.app is signed in and `~/Library/Messages/chat.db` exists.
3) For send, allow the terminal under System Settings → Privacy & Security → Automation → Messages.

## Advanced Features Setup (imsg-plus)

The new typing, read receipt, and tapback features require injecting a dylib into Messages.app to access Apple's private IMCore framework.

### Prerequisites
1. **Disable SIP** (System Integrity Protection):
   - Reboot into Recovery Mode (hold Cmd+R during startup)
   - Open Terminal from the Utilities menu
   - Run: `csrutil disable`
   - Reboot normally

2. **Full Disk Access**: Grant your terminal FDA permission in System Settings → Privacy & Security → Full Disk Access

3. **Build the dylib**:
   ```bash
   make build
   # Creates .build/release/imsg-plus-helper.dylib
   ```

### Usage
Messages.app must be launched with the dylib injected:

```bash
# 1. Quit Messages.app if running
killall Messages 2>/dev/null

# 2. Launch with dylib injection
DYLD_INSERT_LIBRARIES=$PWD/.build/release/imsg-plus-helper.dylib \
  /System/Applications/Messages.app/Contents/MacOS/Messages &

# 3. Verify it's working
imsg status
# Should show: "✅ Available - IMCore framework loaded"

# 4. Use advanced features
imsg typing --handle "user@example.com" --state on
imsg read --handle "user@example.com"
```

### Troubleshooting

**"Advanced features: ❌ Not available"**
- Ensure Messages.app was launched with `DYLD_INSERT_LIBRARIES`
- Check IPC files exist: `ls ~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-*`
- Restart Messages.app with dylib injection

**Typing indicator doesn't appear**
- Typing bubbles show on the *recipient's* device, not yours
- Test with another device or ask the recipient to confirm

**Conflicts with BlueBubbles**
- Only one dylib can inject into Messages.app at a time
- Disable BlueBubbles before using imsg-plus advanced features

**Security Warning**
- These features use Apple's private IMCore framework
- Requires SIP disabled, which reduces system security
- Intended for personal use and testing only
- Re-enable SIP when not needed: `csrutil enable` (from Recovery Mode)

## Testing
```bash
make test
```

Note: `make test` applies a small patch to SQLite.swift to silence a SwiftPM warning about `PrivacyInfo.xcprivacy`.

## Linting & formatting
```bash
make lint
make format
```

## Core library
The reusable Swift core lives in `Sources/IMsgCore` and is consumed by the CLI target. Apps can depend on the `IMsgCore` library target directly.
