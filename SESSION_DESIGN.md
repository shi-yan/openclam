# Session Architecture Design

## Overview

OpenClam supports multiple concurrent automation sessions. A session is a self-contained unit of agent work: it owns its agent loop, its browser tabs, its conversation history, and its persistence. The main app (UI thread) stays responsive and never owns agent state.

Sessions can be triggered by user prompts or by a cron scheduler. Both produce identical session objects; the trigger type is metadata.

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                    Main App (UI Thread / CEF TID_UI)          │
│                                                               │
│  SessionManager          BrowserActionDispatcher              │
│  ├── create_session()    ├── execute_js(tab_id, ...)          │
│  ├── destroy_session()   ├── take_screenshot(tab_id)          │
│  └── sessions map        ├── read_dom(tab_id)                 │
│                          └── inject_input_event(tab_id, ...)  │
│                                                               │
│  ← CefPostTask ──────────────────── (MPSC: sessions → main)  │
│  → session.inbox ────────────────── (SPSC: main → session)   │
└──────────────────────────────────────────────────────────────┘
          │                                    │
   ┌──────┴──────┐                      ┌──────┴──────┐
   │  Session A  │                      │  Session B  │
   │  Worker     │                      │  Worker     │
   │  Thread     │                      │  Thread     │
   │             │                      │             │
   │  AgentLoop  │                      │  AgentLoop  │
   │  tabs[0..n] │                      │  tabs[0..n] │
   │  SQLiteDB   │                      │  SQLiteDB   │
   └─────────────┘                      └─────────────┘
```

---

## Core Data Structures

### Tab

Each session can own multiple browser tabs. A tab has a unique ID scoped to the session.

```cpp
struct Tab {
    std::string tab_id;        // e.g. "s3-t0", "s3-t1"
    BrowserTabMac* browser;    // owned by main thread — do not touch from worker
    std::string current_url;   // updated by main thread on navigation
    std::string title;
};
```

Tab IDs are stable for the lifetime of the session. When the agent calls a browser tool, it must supply a `tab_id`. This lets the dispatcher look up the correct `BrowserTabMac` on the UI thread.

Tab ID format: `<session_id_short>-t<index>` — e.g. session `a1b2`, tab 0 → `a1b2-t0`.

### Session Status

```cpp
enum class SessionStatus {
    Created,
    Running,
    WaitingForTool,    // blocked waiting for a BrowserActionResult
    WaitingForUser,    // agent explicitly asked for user input
    Completed,
    Failed,
    Cancelled,
};
```

---

## Session Class

```cpp
class Session {
public:
    // Identity
    std::string  session_id;
    SessionStatus status;
    TriggerType  trigger;   // UserPrompt | Cron

    // Tabs — created/destroyed on main thread, read-only from worker
    // worker only reads tab_id strings; all tab operations go through dispatch
    std::vector<Tab> tabs;

    // Persistence
    std::unique_ptr<SessionStore> store;   // wraps SQLite file

    // Worker
    std::thread worker_thread;

    // Inbox: main → worker  (SPSC)
    struct Inbox {
        std::mutex              mu;
        std::condition_variable cv;
        std::deque<InboxMessage> queue;

        void push(InboxMessage msg);
        InboxMessage wait(std::chrono::milliseconds timeout);
    } inbox;

    // Lifecycle
    void start();   // spawns worker_thread
    void cancel();  // pushes CancelSignal to inbox, joins thread
};
```

The worker thread **only** sends messages to the main app via `CefPostTask(TID_UI, ...)`. It never touches CEF, AppKit, or tab objects directly.

---

## Communication Channels

### Channel 1: Worker → Main  (MPSC via CefPostTask)

CEF's `CefPostTask(TID_UI, callback)` is the MPSC channel. Each session worker posts closures onto CEF's UI task queue. The UI thread processes them in order on its natural event loop tick. No custom queue or polling needed. Cross-platform.

```cpp
// Called from worker thread:
CefPostTask(TID_UI, base::BindOnce(
    &MainApp::OnSessionMessage, app_, session_id_, std::move(msg)));
```

**Message types (worker → main):**

```cpp
struct DisplayMessage {
    std::string role;         // "assistant" | "tool_call" | "tool_result"
    std::string text;
    bool        is_thinking;
    int64_t     timestamp_ms;
};

struct BrowserActionRequest {
    std::string request_id;   // UUID — must be echoed back in result
    std::string session_id;
    std::string tab_id;       // which tab to act on
    BrowserAction action;     // see Browser Actions section
};

struct SessionStatusUpdate {
    SessionStatus new_status;
    std::string   detail;     // error message if Failed
};

struct AllocateTabRequest {
    std::string request_id;
    std::string session_id;
    std::string initial_url;  // may be empty
};

using OutboundMessage = std::variant<
    DisplayMessage,
    BrowserActionRequest,
    SessionStatusUpdate,
    AllocateTabRequest
>;
```

### Channel 2: Main → Worker  (SPSC per session via Inbox)

The main app pushes results and user inputs into `session.inbox`. The worker blocks on `inbox.wait(timeout)` when it needs a result.

```cpp
struct ToolResult {
    std::string request_id;   // matches BrowserActionRequest::request_id
    bool        success;
    std::string payload;      // JSON string
};

struct UserInput {
    std::string text;
};

struct TabAllocated {
    std::string request_id;
    std::string tab_id;       // newly allocated tab ID
};

struct CancelSignal {};

using InboxMessage = std::variant<
    ToolResult,
    UserInput,
    TabAllocated,
    CancelSignal
>;
```

---

## Agent Loop (Worker Thread)

The loop runs entirely on the worker thread. All blocking is done here; the UI thread is never blocked.

```cpp
void Session::run_agent_loop() {
    while (true) {
        // 1. Build message array from SQLite context table
        auto messages = store->load_context();

        // 2. Call Claude API — blocking HTTP with streaming
        auto response = claude_api_.complete(messages, tools_, [&](Delta delta) {
            // streaming callback — still on worker thread
            if (delta.is_text()) {
                post_display_message(delta.text);
                store->append_context_delta(delta);
            }
        });

        if (response.stop_reason == StopReason::EndTurn) {
            post_status(SessionStatus::Completed);
            return;
        }

        if (response.stop_reason == StopReason::ToolUse) {
            post_status(SessionStatus::WaitingForTool);

            for (auto& tool_call : response.tool_calls) {
                // Notify UI of the tool call being dispatched
                post_display_message(tool_call.render());

                // Request browser action from main thread
                std::string req_id = new_uuid();
                post_browser_action(req_id, tool_call);

                // Block until result arrives (or timeout/cancel)
                auto inbox_msg = inbox.wait(std::chrono::seconds(120));

                if (std::holds_alternative<CancelSignal>(inbox_msg)) {
                    post_status(SessionStatus::Cancelled);
                    return;
                }

                auto& result = std::get<ToolResult>(inbox_msg);
                store->append_tool_result(tool_call.id, result);
                post_display_message(render_tool_result(result));
            }

            post_status(SessionStatus::Running);
            // loop continues — feed tool results back to Claude
        }

        // Check for queued UserInput between turns
        if (auto msg = inbox.try_pop()) {
            if (std::holds_alternative<UserInput>(*msg)) {
                store->append_user_message(std::get<UserInput>(*msg).text);
            } else if (std::holds_alternative<CancelSignal>(*msg)) {
                post_status(SessionStatus::Cancelled);
                return;
            }
        }
    }
}
```

**Why thread + blocking loop (not coroutines):**
The agent loop has one sequential critical path: build context → call API → dispatch tools → repeat. A blocking while loop is the natural expression of this. C++20 coroutines add syntactic overhead for no architectural gain here. The thread cost is negligible vs. the API latency (seconds per turn). If sessions scale into the hundreds, revisit with a thread pool + callback chain — but the interface (inbox/outbox messages) remains the same.

---

## Browser Actions

All browser actions are routed through the main thread dispatcher. The worker never calls CEF directly.

```cpp
// Discriminated union of all possible browser actions
struct NavigateTo    { std::string url; };
struct InjectJS      { std::string script; };          // returns JSON result
struct TakeScreenshot{};                               // returns base64 PNG
struct ReadDOM       { std::string selector; };        // returns HTML string
struct SimulateClick { int x; int y; MouseButton btn; };
struct SimulateKey   { std::string key; std::string modifiers; };
struct CloseTab      {};
struct FocusTab      {};

using BrowserAction = std::variant<
    NavigateTo, InjectJS, TakeScreenshot, ReadDOM,
    SimulateClick, SimulateKey, CloseTab, FocusTab
>;
```

**Dispatch flow:**

```
Worker:   post BrowserActionRequest { req_id="abc", tab_id="s3-t1", InjectJS{...} }
            ↓  CefPostTask
Main:     BrowserActionDispatcher::dispatch(request)
            → look up BrowserTabMac by tab_id
            → call CefFrame::ExecuteJavaScript(...)
            → on completion callback (may be async CEF IPC to renderer):
                session.inbox.push(ToolResult { req_id="abc", payload })
            ↓
Worker:   inbox.wait() returns ToolResult { req_id="abc" }
            → store result in SQLite context
            → continue loop
```

For synchronous CEF calls (e.g., `WasHidden`, `Navigate`), the result is pushed to the inbox immediately in the dispatch handler. For async calls (e.g., JS execution that requires renderer IPC), the result is pushed from the async callback.

---

## SQLite Store

One `.db` file per session:

```
~/.openclam/sessions/<session_id>/session.db
```

**Schema:**

```sql
PRAGMA journal_mode=WAL;   -- enables concurrent reader + writer

-- Full agent context: sent verbatim to Claude API
CREATE TABLE context (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    role        TEXT    NOT NULL,   -- 'user' | 'assistant' | 'tool_result'
    content     TEXT    NOT NULL,   -- JSON (Claude message format)
    token_est   INTEGER,
    created_at  INTEGER NOT NULL    -- unix ms
);

-- Chat history: display layer, subset of context with UI metadata
CREATE TABLE chat_history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    role        TEXT    NOT NULL,
    text        TEXT    NOT NULL,
    is_thinking INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL
);

-- Session metadata: all scalar fields
CREATE TABLE session_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- Rows: session_id, status, trigger_type, model, created_at,
--       completed_at, total_tokens_in, total_tokens_out

-- Tabs: persisted so session can be restored
CREATE TABLE tabs (
    tab_id      TEXT PRIMARY KEY,
    current_url TEXT,
    title       TEXT,
    tab_index   INTEGER NOT NULL
);
```

**Threading rules:**

- Worker thread: one read-write connection — writes context, chat_history (agent turns), tabs
- Main thread: one read-only connection — reads chat_history for UI rendering, reads tabs for display
- WAL mode allows one writer + multiple readers with no locking conflicts
- User message writes (from main thread): routed via `CefPostTask` back to the worker thread, so that all writes go through one connection. This avoids any write contention entirely.

---

## SessionManager

Lives on the main thread. Owns all sessions.

```cpp
class SessionManager {
public:
    Session& create_session(TriggerType trigger, std::string initial_prompt);
    void     destroy_session(const std::string& session_id);
    Session* find_session(const std::string& session_id);

    // Called by CefPostTask deliveries
    void on_session_message(std::string session_id, OutboundMessage msg);

private:
    std::unordered_map<std::string, std::unique_ptr<Session>> sessions_;
    BrowserActionDispatcher dispatcher_;

    void handle_display_message(Session&, DisplayMessage);
    void handle_browser_action(Session&, BrowserActionRequest);
    void handle_status_update(Session&, SessionStatusUpdate);
    void handle_allocate_tab(Session&, AllocateTabRequest);
};
```

---

## Cron Scheduler

The scheduler runs on the main thread (a repeating `NSTimer` or `CefPostDelayedTask`). When a trigger fires, it calls `SessionManager::create_session(CronTrigger{...})`. Cron sessions start with no tabs; the agent's first action is typically `AllocateTabRequest`.

Cron job definition is stored separately (e.g., `~/.openclam/crons.json`):

```json
{
  "cron_id": "daily-news",
  "schedule": "0 8 * * *",
  "prompt": "Open HN and summarize the top 5 posts",
  "model": "claude-opus-4-6"
}
```

---

## Context Compaction

When the `context` table's total `token_est` approaches the model's context limit (threshold: ~80% of limit), the worker triggers compaction before the next API call:

1. Take the oldest 50% of context rows (excluding the system prompt row)
2. Send them to Claude with a summarization prompt: `"Summarize this conversation history concisely"`
3. Replace those rows with a single synthetic `user` row: `[summary: <text>]`
4. Update `token_est` accordingly

This is transparent to the ongoing session. The summary row is marked with `role='summary'` in SQLite for auditability but sent as a `user` turn to the API.

---

## Vue Panel Integration

The chat panel (`frontend/tabs_chat/`) needs to receive `DisplayMessage` events in real time.

The main thread handler for `DisplayMessage` calls:

```cpp
// In handle_display_message, running on UI thread:
std::string js = std::format(
    "window.__openclam.onAgentMessage({});",
    message.to_json()
);
tabs_chat_browser_->GetMainFrame()->ExecuteJavaScript(js, "", 0);
```

The Vue panel exposes `window.__openclam.onAgentMessage(msg)` which appends to its reactive chat state.

For session status updates, the sessions panel (`frontend/sessions/`) is updated similarly via its own CEF browser view.

---

## Implementation Phases

### Phase 1 — Core Infrastructure

**Goal:** Session objects exist, can be created/destroyed, SQLite files are managed.

- [ ] `SessionStore` class: open/create SQLite file, WAL mode, schema migration
- [ ] `Session` class: fields, status enum, inbox queue (SPSC)
- [ ] `SessionManager` class: create/destroy/find sessions, no agent logic yet
- [ ] Tab allocation: `AllocateTabRequest` flow — main thread creates a `BrowserTabMac`, assigns a tab ID, pushes `TabAllocated` to inbox
- [ ] Session ID and tab ID generation utilities
- [ ] Persist tab list and session metadata to SQLite on every change

**Deliverable:** `SessionManager::create_session()` creates a session with one tab, persists to disk, and can be destroyed cleanly.

---

### Phase 2 — Agent Loop Skeleton

**Goal:** Worker thread runs a loop, can receive messages, shuts down cleanly.

- [ ] `Session::start()` spawns worker thread running `run_agent_loop()`
- [ ] Loop reads from inbox, handles `CancelSignal` and `UserInput`
- [ ] `CefPostTask` wrappers: `post_display_message()`, `post_status()`, `post_browser_action()`
- [ ] Main thread `on_session_message()` dispatcher: routes variants to handlers
- [ ] Stub browser action dispatcher: receives request, immediately returns dummy `ToolResult`
- [ ] `Session::cancel()`: pushes cancel signal, joins thread with timeout

**Deliverable:** Worker thread loops, sends dummy messages to UI, shuts down cleanly on cancel. No real Claude calls yet.

---

### Phase 3 — Browser Action Dispatcher

**Goal:** All browser tools work end-to-end from worker thread to CEF and back.

- [ ] `BrowserActionDispatcher` class with `dispatch(BrowserActionRequest)` method
- [ ] Tab lookup by `tab_id` (thread-safe read of `Session::tabs` — main thread owns tabs)
- [ ] Implement each action:
  - [ ] `NavigateTo` — `CefFrame::LoadURL`, completion via `OnLoadEnd` handler
  - [ ] `InjectJS` — `CefFrame::ExecuteJavaScript` + `CefMessageRouterBrowserSide` for return value
  - [ ] `TakeScreenshot` — `CefBrowserHost::SendCaptureLostEvent` or off-screen rendering snapshot
  - [ ] `ReadDOM` — `InjectJS` with `document.documentElement.outerHTML`
  - [ ] `SimulateClick` / `SimulateKey` — `CefBrowserHost::SendMouseClickEvent` / `SendKeyEvent`
  - [ ] `CloseTab` / `FocusTab` — `SessionManager` tab lifecycle methods
- [ ] Async result routing: completion callbacks push `ToolResult` to correct session inbox

**Deliverable:** Agent (stubbed) can navigate, inject JS, take screenshots, and receive results.

---

### Phase 4 — Claude API Integration

**Goal:** Real Claude API calls inside the agent loop.

- [ ] Claude API client: streaming HTTP, handles tool_use and end_turn stop reasons
- [ ] Tool schema definitions (JSON) for all browser actions
- [ ] `store->load_context()` builds Claude-format message array from SQLite
- [ ] `store->append_*` methods for assistant turns, tool calls, tool results
- [ ] Token estimation (tiktoken or character heuristic) for compaction threshold
- [ ] System prompt construction: browser context, available tools, session goal
- [ ] End-to-end: user types a prompt → session created → Claude called → tool dispatched → result fed back → loop continues

**Deliverable:** Full agentic loop working for simple single-tab tasks.

---

### Phase 5 — Session Management & UI

**Goal:** Sessions visible in the Sessions panel, chat history in the Chat panel.

- [ ] `DisplayMessage` → `ExecuteJavaScript` into `tabs_chat` Vue panel
- [ ] `SessionStatusUpdate` → `ExecuteJavaScript` into `sessions` Vue panel
- [ ] Vue: `window.__openclam.onAgentMessage(msg)` handler in tabs_chat
- [ ] Vue: session list rendering in sessions panel, status badges
- [ ] User input from chat panel → `CefPostTask` → `session.inbox.push(UserInput{...})`
- [ ] Session history on app restart: scan `~/.openclam/sessions/`, show completed sessions

**Deliverable:** Full UI feedback loop — user sees agent thinking in real time.

---

### Phase 6 — Cron & Multi-Tab

**Goal:** Scheduled sessions and sessions with multiple tabs.

- [ ] Cron definition file (`~/.openclam/crons.json`), loaded at startup
- [ ] Cron scheduler on main thread (macOS: `NSTimer` polling, or `CefPostDelayedTask`)
- [ ] `AllocateTabRequest` from worker (for cron sessions that start tabless)
- [ ] Multi-tab agent tools: `open_new_tab`, `close_tab`, `switch_active_tab`
- [ ] Tab state updates (URL, title) pushed to SQLite when `OnLoadEnd` fires

**Deliverable:** Cron-triggered sessions run automatically; agents can open and manage multiple tabs.

---

### Phase 7 — Context Compaction & Resilience

**Goal:** Long-running sessions don't hit token limits; sessions survive crashes.

- [ ] Token budget tracking in agent loop; trigger compaction at 80% of limit
- [ ] Summarization call to Claude; replace old rows in SQLite
- [ ] Session recovery: on startup, find `Running`/`WaitingForTool` sessions in SQLite, offer to resume
- [ ] Inbox persistence: unsent `ToolResult`s that were in-flight at crash time handled gracefully (re-dispatch or surface as error)
- [ ] Tool call timeout handling: if `inbox.wait(120s)` expires, mark session as `Failed` with diagnostic message

**Deliverable:** Sessions can run indefinitely; app restarts don't lose in-progress work.

---

## Open Questions

1. **Screenshot implementation**: CEF off-screen rendering (OSR) mode produces pixel buffers but requires `windowless_rendering_enabled=true` at browser creation time, which changes how the view renders. Need to decide: OSR for all tabs (heavier), or use `kCGWindowImageDefault` CGWindow capture (macOS-only, simpler for on-screen tabs).

2. **JS return values**: `CefFrame::ExecuteJavaScript` is fire-and-forget. Returning values requires `CefMessageRouterBrowserSide` (message passing from renderer to browser process). This adds complexity in Phase 3 — consider whether all JS results can be passed back as JSON strings via a predefined message channel.

3. **Multiple sessions, one active tab view**: The center panel shows one tab at a time. When a background session navigates a tab, the navigation happens but isn't visible. Consider a tab ownership model: only sessions in the foreground drive the visible tab; others operate in hidden `BrowserTabMac` instances.

4. **Claude API key management**: API key stored in macOS Keychain via `SecItemAdd`/`SecItemCopyMatching`. Set once on first launch, never stored in plaintext. Worker thread reads it from keychain at session start.

5. **Concurrent write contention on SQLite (chat_history)**: Routing all SQLite writes through the worker thread (via inbox messages) eliminates contention at the cost of minor latency for user message persistence. If this feels too indirect, a second approach is to open separate connections per thread and rely on WAL serialization — simpler but requires testing under load.
