# 💬 imsg — Send, read, stream iMessage & SMS

A macOS Messages.app CLI to send, read, and stream iMessage/SMS (with attachment metadata). Read-only for receives; send uses AppleScript to drive Messages.app.

## Features
- List chats, view history, or tail new messages (`watch`).
- Send text and attachments via iMessage or SMS (AppleScript, no private APIs).
- Phone normalization to E.164 for reliable buddy lookup (`--region`, default US).
- Optional attachment metadata output (mime, name, path, missing flag).
- Filters: participants, start/end time, JSON output for tooling.
- Read-only DB access (`mode=ro`), no DB writes.

## Requirements
- macOS with Messages.app signed in.
- Full Disk Access for your terminal to read `~/Library/Messages/chat.db`.
- Automation permission for your terminal to control Messages.app (for sending).
- For SMS relay, enable “Text Message Forwarding” on your iPhone to this Mac.

## Install
```bash
go install github.com/steipete/imsg/cmd/imsg@latest
```

## Commands
- `imsg chats [--limit 20] [--json]` — list recent conversations.
- `imsg history --chat-id <id> [--limit 50] [--attachments] [--participants +15551234567,...] [--start 2025-01-01T00:00:00Z] [--end 2025-02-01T00:00:00Z] [--json]`
- `imsg watch [--chat-id <id>] [--since-rowid <n>] [--interval 2s] [--attachments] [--participants …] [--start …] [--end …] [--json]`
- `imsg send --to <handle> [--text "hi"] [--file /path/img.jpg] [--service imessage|sms|auto] [--region US]`

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
imsg watch --chat-id 1 --attachments --interval 2s

# send a picture
imsg send --to "+14155551212" --text "hi" --file ~/Desktop/pic.jpg --service imessage
```

## Examples
```bash
imsg chats --limit 5
imsg chats --limit 5 --json
imsg history --chat-id 1 --attachments --start 2025-01-01T00:00:00Z --json
imsg watch --chat-id 1 --attachments --participants +15551234567
imsg send --to "+14155551212" --text "ping" --file ~/Desktop/pic.png --service imessage
```

## Attachment notes
`--attachments` prints per-attachment lines with name, MIME, missing flag, and resolved path (tilde expanded). Only metadata is shown; files aren’t copied.

## JSON output
`imsg chats --json` emits one JSON object per chat with fields: `id`, `name`, `identifier`, `service`, `last_message_at`.
`imsg history --json` and `imsg watch --json` emit one JSON object per message with fields: `id`, `chat_id`, `sender`, `is_from_me`, `text`, `created_at`, `attachments` (array of metadata).

## Permissions troubleshooting
If you see “unable to open database file” or empty output:
1) Grant Full Disk Access: System Settings → Privacy & Security → Full Disk Access → add your terminal.
2) Ensure Messages.app is signed in and `~/Library/Messages/chat.db` exists.
3) For send, allow the terminal under System Settings → Privacy & Security → Automation → Messages.

## Testing
```bash
go test ./...
```

## Limitations
- Requires a logged-in macOS user session (osascript needs UI access).
- No attachment export yet (metadata only).
- Polling-based watch (default 2s) — not event driven.
