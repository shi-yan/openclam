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

`BrowserTabMac` is a CEF/AppKit UI object that must only be touched on the main thread. The worker thread needs to reference tabs (by ID) but must never access `BrowserTabMac` directly. `Tab` is the session's lightweight record of a tab — it holds what the worker can safely read, and a `shared_ptr` to the underlying browser object that only the main thread dereferences.

```cpp
struct Tab {
    std::string                    tab_id;       // e.g. "a1b2-t0", "a1b2-t1"
    std::shared_ptr<BrowserTabMac> browser;      // main thread only — never touch from worker
    std::string                    current_url;  // updated by main thread on navigation
    std::string                    title;
};
```

`Session` owns a `std::vector<Tab>`. The worker only reads `tab_id` strings from this vector; the `shared_ptr` is there so the main thread can access the browser object without a separate lookup table. The `SessionManager` also holds `shared_ptr<BrowserTabMac>` references for its own tab bookkeeping.

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
    std::string   session_id;
    SessionStatus status;
    TriggerType   trigger;   // UserPrompt | Cron

    // Tabs — created/destroyed on main thread, read-only from worker
    // worker only reads tab_id strings; all tab operations go through dispatch
    std::vector<Tab> tabs;

    // Persistence
    std::unique_ptr<SessionStore> store;   // wraps SQLite file

    // Worker
    std::thread worker_thread;

    // Inbox: main → worker  (SPSC, lock-free)
    // Uses moodycamel::BlockingConcurrentQueue (concurrentqueue v1.0.4)
    // Added via CMake: FetchContent_Populate(concurrentqueue
    //   URL https://github.com/cameron314/concurrentqueue/archive/refs/tags/v1.0.4.tar.gz)
    moodycamel::BlockingConcurrentQueue<InboxMessage> inbox;

    // Lifecycle
    void start();   // spawns worker_thread
    void cancel();  // enqueues CancelSignal, joins thread
};
```

`inbox.wait_dequeue_timed(item, timeout)` replaces the mutex+cv+deque pattern. `inbox.try_dequeue(item)` for non-blocking polls. No locks needed.

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
    std::string   request_id;  // UUID — must be echoed back in result
    std::string   session_id;
    std::string   tab_id;      // which tab to act on; empty for tab-independent actions
    BrowserAction action;      // see Browser Actions section
};

struct SessionStatusUpdate {
    SessionStatus new_status;
    std::string   detail;      // error message if Failed
};

struct AllocateTabRequest {
    std::string request_id;
    std::string session_id;
    std::string initial_url;   // may be empty
};

using OutboundMessage = std::variant<
    DisplayMessage,
    BrowserActionRequest,
    SessionStatusUpdate,
    AllocateTabRequest
>;
```

### Channel 2: Main → Worker  (SPSC per session via lock-free inbox)

The main app enqueues results and user inputs into `session.inbox`. The worker blocks on `wait_dequeue_timed` when it needs a result.

```cpp
struct ToolResult {
    std::string request_id;  // matches BrowserActionRequest::request_id
    bool        success;
    std::string payload;     // JSON string; for screenshots, a file path reference
};

struct UserInput {
    std::string text;
};

struct TabAllocated {
    std::string request_id;
    std::string tab_id;      // newly allocated tab ID
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

## Tool Categories: Worker-Local vs CEF-Dispatched

Not all tools need to go through the main thread. Tools are categorized at call time:

**Worker-local tools** — execute directly on the worker thread, no dispatch:
- Vision/layout queries: given a screenshot, find bounding box of a UI element (call vision API inline)
- JS generation: ask a sub-Claude call to produce an inject script
- DOM parsing: parse an HTML string already in memory
- Any pure computation or third-party API call (no CEF involvement)

**CEF-dispatched tools** — must go through the main thread via `BrowserActionRequest`:
- Anything that calls `CefFrame`, `CefBrowserHost`, `CefBrowser`, or AppKit objects

This split is important: routing a vision query to the main thread just to call an external HTTP API would add latency and unnecessary CefPostTask overhead. The worker thread is perfectly capable of making its own HTTP calls.

---

## Agent Loop (Worker Thread)

The loop runs entirely on the worker thread. All blocking is done here; the UI thread is never blocked.

### Context Storage in SQLite

Each row in the `context` table is one complete Claude message in JSON format (Claude's native message format: `{role, content: [...blocks]}`). During streaming:

- Text deltas are buffered in a `std::string` accumulator on the worker thread — **not** written per-delta (too many writes).
- When the stream ends (full assistant turn received), one row is written to `context` and one row to `chat_history`.
- Tool calls are part of the assistant message's content blocks and are written as part of that same row.
- Tool results are a separate `tool_result` row written after the result arrives.

`chat_history` is the UI display layer — written at the same time as `context`, but stores only what the user needs to see (text, role, is_thinking). On app startup, `chat_history` rows are loaded to restore the chat panel without re-parsing the full agent context JSON.

### Handling Mixed Inbox Messages While Waiting for a Tool Result

When the worker dispatches a CEF tool and blocks waiting for the result, other inbox messages (e.g., `UserInput`, `CancelSignal`) may arrive before the `ToolResult`. The inner wait loop drains non-result messages into a stash, processes them after the result arrives:

```cpp
ToolResult wait_for_tool_result(const std::string& expected_req_id,
                                std::vector<UserInput>& deferred_inputs) {
    while (true) {
        InboxMessage msg;
        bool got = inbox.wait_dequeue_timed(msg, std::chrono::seconds(120));

        if (!got) {
            throw ToolTimeoutError{expected_req_id};
        }

        if (auto* cancel = std::get_if<CancelSignal>(&msg)) {
            throw CancelledError{};
        }
        if (auto* input = std::get_if<UserInput>(&msg)) {
            deferred_inputs.push_back(std::move(*input));  // stash, handle after
            continue;
        }
        if (auto* result = std::get_if<ToolResult>(&msg)) {
            // guard against stale results if we ever pipeline
            if (result->request_id == expected_req_id) return std::move(*result);
        }
    }
}
```

### Full Loop

```cpp
void Session::run_agent_loop() {
    std::vector<UserInput> deferred_inputs;

    while (true) {
        // Flush any user inputs that arrived during the last tool wait
        for (auto& input : deferred_inputs) {
            store->append_user_message(input.text);
        }
        deferred_inputs.clear();

        // 1. Build message array from SQLite context table
        auto messages = store->load_context();

        // 2. Call Claude API — blocking HTTP with streaming
        //    Text deltas are buffered; written to SQLite only when stream ends
        std::string text_accumulator;
        auto response = claude_api_.complete(messages, tools_, [&](Delta delta) {
            if (delta.is_text()) {
                text_accumulator += delta.text;
                post_display_message(delta.text, /*is_streaming=*/true);
            }
        });

        // Write full assistant turn to both context and chat_history
        store->append_assistant_turn(text_accumulator, response.tool_calls);
        post_display_message_finalize();  // signals UI to stop streaming indicator

        if (response.stop_reason == StopReason::EndTurn) {
            post_status(SessionStatus::Completed);
            return;
        }

        if (response.stop_reason == StopReason::ToolUse) {
            post_status(SessionStatus::WaitingForTool);

            for (auto& tool_call : response.tool_calls) {
                post_display_message(tool_call.render());

                if (is_worker_local_tool(tool_call)) {
                    // Execute directly on worker thread — no dispatch needed
                    auto result = execute_local_tool(tool_call);
                    store->append_tool_result(tool_call.id, result);
                    post_display_message(render_tool_result(result));
                } else {
                    // CEF tool — dispatch to main thread, block for result
                    std::string req_id = new_uuid();
                    post_browser_action(req_id, tool_call);

                    try {
                        auto result = wait_for_tool_result(req_id, deferred_inputs);
                        store->append_tool_result(tool_call.id, result);
                        post_display_message(render_tool_result(result));
                    } catch (const ToolTimeoutError&) {
                        post_status(SessionStatus::Failed, "tool timed out");
                        return;
                    } catch (const CancelledError&) {
                        post_status(SessionStatus::Cancelled);
                        return;
                    }
                }
            }

            post_status(SessionStatus::Running);
            // loop continues — deferred_inputs flushed at top of next iteration
        }

        // Poll for user input between turns (non-blocking)
        InboxMessage msg;
        while (inbox.try_dequeue(msg)) {
            if (std::holds_alternative<UserInput>(msg)) {
                deferred_inputs.push_back(std::get<UserInput>(std::move(msg)));
            } else if (std::holds_alternative<CancelSignal>(msg)) {
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

All CEF browser actions are routed through the main thread dispatcher. Worker-local tools (vision, sub-agent, etc.) skip this channel entirely.

Starting list — intentionally small for Phase 3. Extend as needed.

### Tool Registration

Each tool needs a name (sent to the LLM API), description, JSON Schema, and a dispatch category. The canonical approach is a **central tool table** in `tools.cpp` — one `ToolDefinition` per tool, all in one place. No macros, no scattered JSON files, no compile-time scanning.

```cpp
enum class DispatchCategory {
    WorkerLocal,   // execute directly on worker thread — no CEF required
    CefDispatched, // must run on main thread via BrowserActionRequest
};

struct ToolDefinition {
    std::string      name;          // "navigate_to_url" — what the LLM calls
    std::string      description;   // shown to the LLM in the tool spec
    nlohmann::json   input_schema;  // JSON Schema of parameters
    DispatchCategory category;
};

// In tools.cpp — one entry per tool, all in one place:
const std::vector<ToolDefinition> kTools = {
    {
        "navigate_to_url",
        "Navigate the specified tab to a URL and wait for page load.",
        /* input_schema JSON */,
        DispatchCategory::CefDispatched,
    },
    {
        "inject_js",
        "Execute JavaScript in the specified tab and return the result as JSON.",
        /* input_schema JSON */,
        DispatchCategory::CefDispatched,
    },
    {
        "create_cron_job",
        "Schedule a recurring automation. The agent will be started with the given prompt on the cron schedule.",
        /* input_schema JSON */,
        DispatchCategory::WorkerLocal,
    },
    // ... all other tools
};
```

The worker builds the tool spec array for each API call by iterating `kTools` and converting each entry to the provider's format (Anthropic / OpenAI / Gemini — see API Shim). The agent loop checks `category` at dispatch time. Adding a new tool = one entry in `kTools` + one handler function. No registration macros.

### Action Structs

`tab_id` is moved into each struct so the dispatcher doesn't need a separate field.

```cpp
// CEF-dispatched actions
struct NavigateTo     { std::string tab_id; std::string url; };
struct InjectJS       { std::string tab_id; std::string script; };  // returns JSON result
struct TakeScreenshot { std::string tab_id; };                      // returns file path to PNG
struct ReadDOM        { std::string tab_id; std::string selector; };
struct SimulateClick  { std::string tab_id; int x; int y; MouseButton btn; };
struct SimulateKey    { std::string tab_id; std::string key; std::string modifiers; };
struct TypeText       { std::string tab_id; std::string text; };
struct ScrollPage     { std::string tab_id; int delta_x; int delta_y; };
struct GetElementRect { std::string tab_id; std::string selector; };   // returns DOMRect as JSON
struct ReadConsoleLog { std::string tab_id; };  // Phase 6 — CefDevToolsMessageObserver
struct OpenNewTab     { std::string initial_url; };    // returns new tab_id via TabAllocated
struct CloseTab       { std::string tab_id; };
struct FocusTab       { std::string tab_id; };

// Worker-local actions — executed directly on worker thread, no dispatch needed
struct CreateCronJob  { std::string schedule; std::string prompt; std::string model; };
struct DeleteCronJob  { std::string cron_id; };
struct ListCronJobs   { };

using BrowserAction = std::variant<
    NavigateTo, InjectJS, TakeScreenshot, ReadDOM,
    SimulateClick, SimulateKey, TypeText, ScrollPage,
    GetElementRect, ReadConsoleLog,
    OpenNewTab, CloseTab, FocusTab
>;
```

**Dispatch flow:**

```
Worker:   post BrowserActionRequest { req_id="abc", tab_id="a1b2-t1", InjectJS{...} }
            ↓  CefPostTask
Main:     BrowserActionDispatcher::dispatch(request)
            → look up shared_ptr<BrowserTabMac> by tab_id from session.tabs
            → call CefFrame::ExecuteJavaScript(...)
            → on completion callback (may be async CEF IPC to renderer):
                session.inbox.enqueue(ToolResult { req_id="abc", payload })
            ↓
Worker:   wait_for_tool_result("abc") returns ToolResult
            → store result in SQLite context
            → continue loop
```

For synchronous CEF calls, the result is enqueued immediately. For async calls (JS execution requiring renderer IPC round-trip), the result is enqueued from the completion callback.

---

## SQLite Store

One `.db` file per session:

```
~/.openclam/sessions/<session_id>/session.db
```

**Schema:**

```sql
PRAGMA journal_mode=WAL;   -- enables concurrent reader + writer

-- Full agent context: sent verbatim to Claude API each turn
CREATE TABLE context (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    role        TEXT    NOT NULL,   -- 'user' | 'assistant' | 'tool_result' | 'summary'
    content     TEXT    NOT NULL,   -- JSON in Claude message format
    token_est   INTEGER,
    created_at  INTEGER NOT NULL    -- unix ms
);

-- Chat history: display layer for the chat panel UI
-- Written at the same time as context; loaded on startup to restore chat UI
CREATE TABLE chat_history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    role        TEXT    NOT NULL,   -- 'user' | 'assistant' | 'tool_call' | 'tool_result' | 'compaction_summary'
    text        TEXT    NOT NULL,
    media_path  TEXT,               -- path to screenshot PNG on disk, if applicable
    is_thinking INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL
);

-- Session metadata
CREATE TABLE session_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- Rows: session_id, status, trigger_type, model, created_at,
--       completed_at, total_tokens_in, total_tokens_out

-- Tabs: persisted for session restore
CREATE TABLE tabs (
    tab_id      TEXT PRIMARY KEY,
    current_url TEXT,
    title       TEXT,
    tab_index   INTEGER NOT NULL
);

-- Screenshots: metadata index; actual files are on disk
CREATE TABLE screenshots (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    req_id      TEXT    NOT NULL,
    file_path   TEXT    NOT NULL,   -- ~/.openclam/sessions/<id>/screenshots/<req_id>.png
    width       INTEGER,
    height      INTEGER,
    created_at  INTEGER NOT NULL
);
```

**Screenshot storage rationale:** Screenshots are not stored as BLOBs in SQLite — inline binary data would bloat the DB and make queries slow. Instead, PNGs are written to disk under `sessions/<id>/screenshots/`, and the `context` table stores a JSON reference: `{"type": "image", "source": {"type": "path", "path": "..."}}`. The `screenshots` table is an index for cleanup and UI browsing.

**Threading rules:**

- Worker thread: one read-write connection — writes context, chat_history (agent turns), tabs, screenshots
- Main thread: one read-only connection — reads chat_history for UI rendering
- WAL mode allows one writer + multiple readers without blocking
- User message writes (from main thread via Vue input): sent as `UserInput` through the inbox so the worker writes them — keeps a single writer for all SQLite writes, no contention

---

## Claude API Shim

The worker thread makes blocking HTTP calls directly. No need to route through the main thread.

**HTTP library:** [cpp-httplib](https://github.com/yhirose/cpp-httplib) — header-only, no external dependencies, supports streaming (chunked transfer / SSE). Added via CMake `FetchContent`. This is preferred over libcurl for simplicity.

**JSON library:** [nlohmann/json](https://github.com/nlohmann/json) — header-only, for building request bodies and parsing responses.

**Provider-agnostic interface:**

The shim is abstracted behind `LlmClient`. The worker holds a `unique_ptr<LlmClient>` created at session start based on the configured model name. Each provider translates between the canonical internal message format and its own wire format.

```cpp
class LlmClient {
public:
    // Blocking call; invokes on_delta for each streamed text/thinking chunk.
    // Returns the full response including tool_calls when stream ends.
    virtual ApiResponse complete(
        const std::vector<Message>& messages,
        const std::vector<ToolDefinition>& tools,
        std::function<void(Delta)> on_delta
    ) = 0;
    virtual ~LlmClient() = default;
};

class AnthropicClient : public LlmClient { /* ... */ };  // claude-*
class OpenAiClient    : public LlmClient { /* ... */ };  // gpt-*, o*
class GeminiClient    : public LlmClient { /* ... */ };  // gemini-*

// Factory — selects implementation from model name prefix:
std::unique_ptr<LlmClient> make_llm_client(const std::string& model,
                                            const std::string& api_key);
```

Provider notes:
- **Anthropic**: messages array + `tool_use` / `tool_result` content blocks. SSE with `content_block_delta` events.
- **OpenAI**: messages array + `tool_calls` / `tool` role messages. SSE with `delta.tool_calls` events.
- **Gemini**: `contents` array + `functionCall` / `functionResponse` parts. Gemini supports tool calling OR structured output — not both simultaneously. Always use tool calling mode here.

The canonical `Message` format used internally is Claude-style (it's the richest). `OpenAiClient` and `GeminiClient` translate on the way in and out. `kTools` entries are converted to each provider's tool spec format by the respective client.

Each provider's API key is stored in macOS Keychain under a separate service name (e.g., `openclam.anthropic`, `openclam.openai`, `openclam.gemini`). The worker reads the relevant key at session start.

---

## SessionManager

Lives on the main thread. Owns all sessions.

```cpp
class SessionManager {
public:
    std::shared_ptr<Session> create_session(TriggerType trigger,
                                            std::string initial_prompt);
    void destroy_session(const std::string& session_id);
    std::shared_ptr<Session> find_session(const std::string& session_id);

    // Entry point for all CefPostTask deliveries from worker threads
    void on_session_message(std::string session_id, OutboundMessage msg);

private:
    std::unordered_map<std::string, std::shared_ptr<Session>> sessions_;
    BrowserActionDispatcher dispatcher_;

    void handle_display_message(Session&, DisplayMessage);
    void handle_browser_action(Session&, BrowserActionRequest);
    void handle_status_update(Session&, SessionStatusUpdate);
    void handle_allocate_tab(Session&, AllocateTabRequest);
};
```

---

## Cron Scheduler

The scheduler runs on the main thread (`NSTimer` or `CefPostDelayedTask`). When a trigger fires, it calls `SessionManager::create_session(CronTrigger{...})`. Cron sessions start with no tabs; the agent's first action is typically `AllocateTabRequest` → `OpenNewTab`.

### Agent-Created Cron Jobs

The agent can create, delete, and list cron jobs as worker-local tool calls — no CEF dispatch needed. This enables prompts like "Check this product's price every day" to be handled autonomously: the agent creates a cron job for itself with the appropriate schedule and prompt.

`CreateCronJob`, `DeleteCronJob`, and `ListCronJobs` are `DispatchCategory::WorkerLocal`. The worker executes them directly:
1. Read/write `~/.openclam/crons.json`
2. Post a `ReloadCronSchedule` outbound message to the main thread so the scheduler picks up the change immediately

`ReloadCronSchedule` is added to `OutboundMessage`:
```cpp
struct ReloadCronSchedule {};  // main thread re-reads crons.json and resets NSTimer intervals
```

Cron job definition format in `~/.openclam/crons.json`:

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

Yes — compaction is part of the worker loop. It runs at the top of each iteration, before building the message array, so it is always triggered by the worker thread and never requires external coordination:

```cpp
while (true) {
    // Compaction check — before every API call
    if (store->estimated_tokens() > compaction_threshold_) {
        compact_context();  // summarization sub-call, rewrites SQLite rows in place
    }
    auto messages = store->load_context();
    // ...
}
```

When the `context` table's total `token_est` approaches the model's context limit (threshold: ~80% of limit), the worker triggers compaction before the next API call:

1. Take the oldest 50% of context rows (excluding the system prompt row)
2. Send them to Claude with a summarization prompt: `"Summarize this conversation history concisely"`
3. In `context`: delete those rows, insert one `role='summary'` row containing the summary text
4. In `chat_history`: append one `role='compaction_summary'` row — **do not delete any existing rows**
5. Update `token_est` accordingly

**`context` and `chat_history` diverge intentionally at compaction time:**

| Table | On compaction |
|---|---|
| `context` | Old rows deleted, replaced by one summary row. Mutable — exists to fit the token budget. |
| `chat_history` | Nothing deleted. One `compaction_summary` marker appended. Immutable append-only display log. |

This means the user can scroll back in the chat panel and see the full original conversation, followed by a visual marker like `[ N messages condensed — summary: ... ]`, followed by everything after. The agent's API context is compact; the user's history is complete.

The `compaction_summary` row in `chat_history` stores the summary text in its `text` field. The UI renders it as a collapsed/styled divider card distinct from regular messages.

The `context` summary row is sent to the API as a `user`-role turn (Claude has no native summary role), with a prefix like `[Conversation summary: ...]` to distinguish it from real user messages.

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

On startup, the chat panel calls `window.__openclam.loadHistory(session_id)` which triggers the main thread to read `chat_history` from SQLite and inject the rows via the same `ExecuteJavaScript` path.

For session status updates, the sessions panel (`frontend/sessions/`) is updated similarly via its own CEF browser view.

---

## Implementation Phases

### Phase 1 — Core Infrastructure

**Goal:** Session objects exist, can be created/destroyed, SQLite files are managed.

- [ ] `SessionStore` class: open/create SQLite file, WAL mode, schema migration
- [ ] `Session` class: fields, status enum, lock-free inbox (`moodycamel::BlockingConcurrentQueue`)
- [ ] `SessionManager` class: create/destroy/find sessions, no agent logic yet
- [ ] Tab allocation: `AllocateTabRequest` flow — main thread creates a `BrowserTabMac`, assigns a tab ID, enqueues `TabAllocated`
- [ ] Session ID and tab ID generation utilities
- [ ] Persist tab list and session metadata to SQLite on every change
- [ ] CMake: `FetchContent` for concurrentqueue, cpp-httplib, nlohmann/json

**Deliverable:** `SessionManager::create_session()` creates a session with one tab, persists to disk, and can be destroyed cleanly.

---

### Phase 2 — Agent Loop Skeleton

**Goal:** Worker thread runs a loop, can receive messages, shuts down cleanly.

- [ ] `Session::start()` spawns worker thread running `run_agent_loop()`
- [ ] `wait_for_tool_result()` inner loop with deferred input stashing
- [ ] `CefPostTask` wrappers: `post_display_message()`, `post_status()`, `post_browser_action()`
- [ ] Main thread `on_session_message()` dispatcher: routes variants to handlers
- [ ] Stub browser action dispatcher: receives request, immediately enqueues dummy `ToolResult`
- [ ] `Session::cancel()`: enqueues cancel signal, joins thread with timeout

**Deliverable:** Worker thread loops, sends dummy messages to UI, handles interleaved `UserInput` during tool waits, shuts down cleanly on cancel. No real Claude calls yet.

---

### Phase 3 — Browser Action Dispatcher

**Goal:** All CEF browser tools work end-to-end from worker thread to CEF and back.

- [ ] `BrowserActionDispatcher` class with `dispatch(BrowserActionRequest)` method
- [ ] Tab lookup: `find_session(session_id)` → iterate `session.tabs` by `tab_id` → dereference `shared_ptr<BrowserTabMac>` on main thread
- [ ] Implement each action:
  - [ ] `NavigateTo` — `CefFrame::LoadURL`, completion via `OnLoadEnd` handler
  - [ ] `InjectJS` — `CefFrame::ExecuteJavaScript` + `CefMessageRouterBrowserSide` for return value
  - [ ] `TakeScreenshot` — CGWindow capture (macOS); write PNG to `screenshots/` dir; enqueue path as `ToolResult`
  - [ ] `ReadDOM` — `InjectJS` with `document.querySelector(sel).outerHTML`
  - [ ] `SimulateClick` / `SimulateKey` / `TypeText` — `CefBrowserHost::Send*Event`
  - [ ] `ScrollPage` — `CefBrowserHost::SendMouseWheelEvent`
  - [ ] `GetElementRect` — `InjectJS` with `el.getBoundingClientRect()`
  - [ ] `OpenNewTab` / `CloseTab` / `FocusTab` — `SessionManager` tab lifecycle
- [ ] Async result routing: completion callbacks enqueue `ToolResult` to correct session inbox

**Deliverable:** Agent (stubbed) can navigate, inject JS, take screenshots, scroll, and receive results.

---

### Phase 4 — LLM API Integration

**Goal:** Real LLM API calls inside the agent loop, with provider-agnostic interface supporting Anthropic, OpenAI, and Gemini.

- [ ] `LlmClient` abstract base class with `complete()` interface
- [ ] `AnthropicClient`: cpp-httplib SSE streaming, Anthropic message format
- [ ] `OpenAiClient`: OpenAI chat completions format, tool_calls delta parsing
- [ ] `GeminiClient`: Gemini contents format, functionCall parts, tool-calling mode only
- [ ] `make_llm_client()` factory: selects implementation from model name prefix
- [ ] macOS Keychain read per provider at session start
- [ ] Tool schema definitions (JSON) for all browser actions
- [ ] `store->load_context()` builds Claude-format message array from SQLite
- [ ] `store->append_assistant_turn()`: writes full turn to context + chat_history after stream ends
- [ ] `store->append_tool_result()`: writes tool result row to context + chat_history
- [ ] Token estimation (character heuristic: chars / 4) for compaction threshold
- [ ] System prompt construction: browser context, available tools, session goal
- [ ] Worker-local tool dispatch: `is_worker_local_tool()` check, `execute_local_tool()` stub
- [ ] End-to-end: user types prompt → session created → Claude called → tool dispatched → result fed back → loop continues

**Deliverable:** Full agentic loop working for simple single-tab tasks.

---

### Phase 5 — Session Management & UI

**Goal:** Sessions visible in the Sessions panel, chat history in the Chat panel.

- [ ] `DisplayMessage` → `ExecuteJavaScript` into `tabs_chat` Vue panel
- [ ] `SessionStatusUpdate` → `ExecuteJavaScript` into `sessions` Vue panel
- [ ] Vue: `window.__openclam.onAgentMessage(msg)` handler in tabs_chat
- [ ] Vue: `window.__openclam.loadHistory(session_id)` — loads from SQLite on panel open
- [ ] Vue: session list rendering in sessions panel, status badges
- [ ] User input from chat panel → native message handler → `session.inbox.enqueue(UserInput{...})`
- [ ] Session history on app restart: scan `~/.openclam/sessions/`, show completed sessions

**Deliverable:** Full UI feedback loop — user sees agent thinking in real time, history persists across restarts.

---

### Phase 6 — Cron & Multi-Tab

**Goal:** Scheduled sessions and sessions with multiple tabs.

- [ ] Cron definition file (`~/.openclam/crons.json`), loaded at startup
- [ ] Cron scheduler on main thread (`NSTimer` polling once per minute)
- [ ] `OpenNewTab` action: main thread creates `BrowserTabMac`, assigns tab ID, enqueues `TabAllocated`
- [ ] Multi-tab context: agent receives updated tab list in system prompt each turn
- [ ] Tab state updates (URL, title) written to SQLite when `OnLoadEnd` fires

**Deliverable:** Cron-triggered sessions run automatically; agents can open and manage multiple tabs.

---

### Phase 7 — Context Compaction & Resilience

**Goal:** Long-running sessions don't hit token limits; sessions survive crashes.

- [ ] Token budget tracking in agent loop; trigger compaction at 80% of model limit
- [ ] Summarization sub-call to Claude; replace old rows in SQLite with `role='summary'` row
- [ ] Session recovery: on startup, find `Running`/`WaitingForTool` sessions in SQLite, offer to resume
- [ ] Tool call timeout: if `wait_dequeue_timed` expires, mark session `Failed` with diagnostic
- [ ] Retry logic in `ClaudeApiClient`: exponential backoff on HTTP 529

**Deliverable:** Sessions can run indefinitely; app restarts don't lose in-progress work.

---

## Open Questions

1. **Screenshot implementation**: Resolved — switch to the target tab first, then capture. The `TakeScreenshot` dispatcher will: (1) call `FocusTab` on the target tab to make it visible, (2) wait one render tick (~16ms), (3) capture with `kCGWindowImageDefault`. This is macOS-only but works for all tabs without OSR complexity.

   OSR mode (with Metal texture mapping, as used in the prior project) remains the preferred long-term path for capturing background tabs without switching. Defer to a post-Phase 3 optimization: OSR requires `windowless_rendering_enabled=true` at browser creation time, which changes the rendering pipeline. Design the tab creation path to accept this flag so OSR can be enabled per-tab later without rearchitecting.

2. **JS return values**: `CefFrame::ExecuteJavaScript` is fire-and-forget. Returning values requires `CefMessageRouterBrowserSide` (renderer → browser IPC). This is the main complexity driver in Phase 3 — all `InjectJS`, `ReadDOM`, and `GetElementRect` depend on it.

3. **Multiple sessions, one visible tab**: The center panel shows one tab at a time. For screenshot, the tab-switch approach above means background session tabs are briefly focused during capture. If two sessions race to take screenshots simultaneously, they will momentarily steal focus from each other. A per-session screenshot mutex in the `BrowserActionDispatcher` serializes concurrent `TakeScreenshot` calls.

4. **DevTools Protocol — basic console log support in Phase 6**: `CefDevToolsMessageObserver` is the CEF hook. The `ReadConsoleLog` action (already in `BrowserAction`) will be implemented in Phase 6 as follows: attach a `CefDevToolsMessageObserver` to the browser on tab creation, buffer `Runtime.consoleAPICalled` events in a ring buffer per tab, flush the ring buffer as the `ToolResult` payload when `ReadConsoleLog` is dispatched. This gives the agent visibility into JS errors and `console.log` output — useful for debugging injected scripts. `ReadNetworkLog` is heavier (requires `Network.enable` and event streaming) and stays deferred.
