---
name: osaurus-browser
description: Teaches the agent how to use the headless browser tools — per-agent persistent sessions, the open_login helper, refs, batching, detail levels, console/network inspection, dialogs, viewport/UA, cookies, and lock/unlock for multi-agent safety.
metadata:
  author: Osaurus
  version: "2.0.0"
---

# Osaurus Browser

Headless browser automation via element refs. Every action returns a page snapshot automatically — you rarely need to call `browser_snapshot` separately.

## Per-agent persistent sessions

Your browser session is **persistent across runs and isolated per agent**. Cookies, localStorage, and IndexedDB are stored on disk, keyed by the active agent. That means:

- **Never ask the user for passwords, 2FA codes, OAuth approvals, or any credentials in chat.** The user signs in once via the helper window (see `browser_open_login`); after that you simply call `browser_navigate` and run logged-in.
- **Don't try to type credentials into login forms yourself.** Captchas, risk-based 2FA, and OAuth all break that flow. Use `browser_open_login` instead.
- Two different agents have completely separate browser profiles — agent A signing into Gmail does not log agent B in.

### Sign-in flow

When `browser_navigate` returns a `LOGIN_REQUIRED` error envelope, the response includes the login URL the page redirected to. Your job is:

1. Acknowledge in chat: "I need to sign in to <site>. I'm opening a browser window for you."
2. Call `browser_open_login` with the suggested URL.
3. Wait for the user to confirm in chat that they're done signing in (the tool also returns when the window closes).
4. Retry the original `browser_navigate`.

```json
// 1. Got LOGIN_REQUIRED from browser_navigate
// 2. Open the helper window
{ "url": "https://github.com/login" }
// 3. After the user signs in and closes the window, retry
{ "url": "https://github.com/notifications" }
```

If sign-in fails repeatedly (wrong password, expired session, 2FA issues), ask the user before calling `browser_reset_session` — that tool wipes the entire profile, including any other sites the user signed into for this agent.

## Typical Flow (2 calls)

```
1. browser_navigate(url)             → snapshot with refs [E1] [E2] [E3]
2. browser_do([type E1, type E2, click E3]) → snapshot of result page
```

## Key Concepts

**Element refs** — `browser_navigate` and all actions return refs like `[E1] input`, `[E2] button "Submit"`. Use these refs in subsequent calls.

**Detail levels** — Every tool accepts `detail` to control snapshot verbosity:

- `none` — action result only, no snapshot (~10 tokens)
- `compact` — single-line refs, default for actions (~200 tokens)
- `standard` — multi-line with attributes, default for `browser_snapshot` (~500 tokens)
- `full` — all attributes + IDs + aria-labels + page text excerpt (~1000+ tokens)

Use `compact` (default) for speed. Use `full` when you need to identify elements by ID or aria-label on complex pages.

## Tools

### browser_navigate

Navigate and get initial page snapshot.

```json
{ "url": "https://example.com", "detail": "compact" }
```

Use `wait_until: "networkidle"` for SPAs.

### browser_do

**Primary interaction tool.** Batch multiple actions in one call. All refs from the previous snapshot stay valid throughout the batch.

```json
{
  "actions": [
    { "action": "type", "ref": "E1", "text": "user@example.com" },
    { "action": "type", "ref": "E2", "text": "password123" },
    { "action": "click", "ref": "E3" }
  ],
  "detail": "compact"
}
```

Supported actions: `click`, `type`, `select`, `hover`, `scroll`, `press_key`, `wait_for`.

If an action fails, execution stops and the response includes: which action failed (index), the error, and a snapshot of current state for recovery.

Use `wait_after: "domstable"` or `"networkidle"` when the last action triggers async content.

### browser_click / browser_type / browser_select / browser_hover / browser_scroll

Individual action tools — each returns a snapshot automatically. Prefer `browser_do` when performing 2+ actions in sequence.

### browser_snapshot

Re-inspect the page without acting. Usually not needed since actions auto-return snapshots. Use when you need to re-check after `browser_wait_for` or `browser_execute_script`.

### browser_press_key

Press keyboard keys: `Enter`, `Escape`, `Tab`, arrow keys, or characters with modifiers.

### browser_wait_for

Wait for text to appear, disappear, or a specified time.

### browser_screenshot

Visual debugging — saves a PNG. Use `full_page: true` for the entire scrollable page.

### browser_execute_script

Escape hatch for arbitrary JavaScript.

## Sign-in tools (2.0.0)

### browser_open_login

Opens a visible browser window so the user can sign in. Cookies are saved per-agent and are immediately visible to your subsequent `browser_navigate` calls.

```json
{ "url": "https://github.com/login" }
{ "url": "https://github.com/login", "timeout_ms": 600000 }
{ }   // open a blank window so the user can navigate freely
```

Returns when the user closes the window or `timeout_ms` (default 5 min) elapses. Response includes `final_url` so you can confirm where the user ended up.

**Always reach for this when you hit a login wall.** Never type passwords yourself.

### browser_reset_session

Wipes the active agent's profile. Closes the headless browser and removes the on-disk data store (cookies, localStorage, IndexedDB, cache). Next `browser_navigate` spawns a fresh logged-out profile.

```json
{}
```

Destructive — confirm with the user first.

## Inspection tools (2.0.0)

These tools return the standard JSON envelope (`{ok, data}` or `{ok:false, error:{code,message,hint?}}`).

### browser_console_messages

Read JavaScript console output captured since page load. Useful for diagnosing client-side errors.

```json
{ "level": "error", "clear": false }
```

Returns `data.messages: [{level, message, timestamp, location}]`.

### browser_network_requests

List fetch/XHR requests the page has made. Use `failed_only: true` to surface 4xx/5xx and network errors.

```json
{ "failed_only": true, "url_contains": "/api/" }
```

Returns `data.requests: [{method, url, status, ok, duration_ms, kind}]`.

### browser_handle_dialog

**Pre-register** the policy for the next `alert` / `confirm` / `prompt` *before* the action that triggers it.

```json
{ "action": "accept", "prompt_text": "yes" }
{ "action": "dismiss" }
{ "action": "status" }
```

Default policy if you never call this is `accept`.

## Environment tools

### browser_set_viewport

Resize the headless WebKit viewport (e.g. mobile-emulation widths).

### browser_set_user_agent

Override the User-Agent header for subsequent navigations. Pass empty/null to reset.

### browser_cookies

```json
{ "action": "get", "domain": "example.com" }
{ "action": "set", "cookie": { "name": "x", "value": "y", "domain": "example.com" } }
{ "action": "clear", "domain": "example.com" }
```

## Multi-agent coordination

### browser_lock

Cooperative lock so two agents don't fight over the same headless browser. Advisory only — other agents are expected to honor it.

```json
{ "action": "lock", "owner": "agent-alice" }
... do work ...
{ "action": "unlock", "owner": "agent-alice" }
{ "action": "status" }
```

If `lock` returns `{ok: false, error: {code: "LOCK_HELD", ...}}`, wait and retry.

## Tips

- Always start with `browser_navigate` — it gives you the refs you need.
- Batch with `browser_do` to minimize round-trips.
- Use `detail: "none"` for intermediate actions where you already know the next step.
- If refs go stale (page changed unexpectedly), call `browser_snapshot` to get fresh ones.
- For SPAs, use `wait_until: "networkidle"` on navigate, or `wait_after: "domstable"` on browser_do.
- Prefer **refs over selectors**. CSS selectors are escaped for safety, but a ref is unambiguous.
- After triggering a JS error you suspect, call `browser_console_messages({"level": "error"})` to confirm.
- Before form submissions that show a confirm dialog, call `browser_handle_dialog({"action": "accept"})`.
- **For any login wall, call `browser_open_login`. Never type credentials.**

## Known limits

- WebKit-based — some sites (Cloudflare-protected, Google sign-in, banks) detect the WebKit fingerprint and may block sign-in even in the helper window. If that happens, surface the error to the user; the upcoming `osaurus.chrome` plugin will provide a real-Chromium driver for those sites.
- The helper window has no password manager / autofill — the user types credentials by hand. They only need to do this once per site per agent; the session persists from then on.
