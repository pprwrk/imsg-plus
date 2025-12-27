# Changelog

## Unreleased
- feat: add JSON output for `imsg chats` and document usage
- fix: drop sqlite `immutable` flag so new messages/replies show up (thanks @zleman1593)
- chore: update go dependencies

## 0.1.0 - 2025-12-20
- initial release: `chats`, `history`, `watch`, `send` (text + attachments)
- JSON output for `history`/`watch` for tooling
- attachment metadata output + fallback decoding
- clearer Full Disk Access permission error
