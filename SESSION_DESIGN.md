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

// Fired by the main thread when a subscribed browser event occurs.
// For sync-blocking events (needs_resolve=true), the worker must call
// ResolveSyncEvent within the timeout or the main thread auto-resolves.
struct EventNotification {
    std::string subscription_id;  // matches SubscribeToEvent ToolResult payload
    std::string event_type;       // "mutation" | "console_error" | "network_request" | "download"
    std::string payload;          // JSON event data
    bool        needs_resolve = false;
    std::string callback_id;      // non-empty when needs_resolve=true
};

using InboxMessage = std::variant<
    ToolResult,
    UserInput,
    TabAllocated,
    CancelSignal,
    EventNotification
>;
```

---

## Tool Categories

Tools are split into three categories based on dispatch path:

**Worker-local tools** — execute directly on the worker thread, no main thread involved:
- Vision/layout queries (call vision API inline)
- JS script generation (sub-Claude call)
- DOM parsing of already-fetched HTML
- Pure computation, third-party HTTP calls
- `Sleep`, `CreateCronJob`, `DeleteCronJob`, `ResolveSyncEvent`

**CEF-dispatched tools** — must run on the main thread via `BrowserActionRequest`:
- Anything calling `CefFrame`, `CefBrowserHost`, `CefBrowser`, or AppKit objects
- `NavigateTo`, `InjectJS`, `TakeScreenshot`, `ReadDOM`, `SimulateClick`, etc.

**Subscription tools** — a new category that initiates a persistent event stream:
- `SubscribeToEvent`, `UnsubscribeFromEvent`
- One outbound `BrowserActionRequest` → one `ToolResult` (the `subscription_id`)
- Then zero or more `EventNotification` inbox messages arrive asynchronously

---

## Event Subscriptions

The request-response model is insufficient for browser automation. Many important signals are asynchronous events, not responses to a single action: DOM mutations, network requests, JS console errors, file downloads. The design extends the inbox with a new message type and adds two new tool categories.

### New inbox message: EventNotification

```cpp
struct EventNotification {
    std::string subscription_id;  // matches the SubscribeToEvent result
    std::string event_type;       // "mutation" | "console_error" | "network_request" |
                                  // "download_started" | ...
    std::string payload;          // JSON event data
    bool        needs_resolve = false;  // true for sync-blocking events (see below)
    std::string callback_id;            // non-empty when needs_resolve=true
};

// Updated inbox variant:
using InboxMessage = std::variant<
    ToolResult,
    UserInput,
    TabAllocated,
    CancelSignal,
    EventNotification   // ← new
>;
```

### New tools

```cpp
// Subscription tools (CEF-dispatched, return subscription_id in ToolResult)
struct SubscribeToEvent {
    std::string tab_id;
    std::string event_type;  // "mutation" | "console_error" | "network_request" | "download"
    std::string filter;      // optional JSON (CSS selector, URL pattern, log level, ...)
};
struct UnsubscribeFromEvent {
    std::string subscription_id;
};

// Sync-event resolution (worker-local — no CEF dispatch needed;
// the main thread already holds the callback, just needs the decision)
struct ResolveSyncEvent {
    std::string callback_id;
    bool        allow;
    std::string params;  // e.g. {"save_path": "/tmp/file.pdf"} for downloads
};

// Wait tools
struct Sleep            { int duration_ms; };  // worker-local: std::this_thread::sleep_for
struct WaitForCondition {                       // worker polls InjectJS until truthy or timeout
    std::string tab_id;
    std::string js_expr;          // e.g. "document.querySelector('.loaded') !== null"
    int         timeout_ms   = 10000;
    int         poll_interval_ms = 500;
};
```

`NavigateTo` is extended with an optional `wait_for_selector`:
```cpp
struct NavigateTo {
    std::string tab_id;
    std::string url;
    std::string wait_for_selector = "";  // if set, also polls for this selector after OnLoadEnd
    int         selector_timeout_ms = 5000;
};
```

### How EventNotifications flow through the loop

The worker drains `EventNotification`s at two points:

1. **Inside `wait_for_tool_result()`** — stash them (same as `UserInput`); do not process mid-tool-wait.
2. **Top of the outer loop** — flush all stashed notifications into context as `tool_result` blocks (using `subscription_id` as `tool_use_id`), then continue to the next API call.

This means the LLM "sees" accumulated events at the start of each turn, in chronological order. This is valid Claude API format and requires no special API support.

### Synchronous blocking events (intercept-and-hold)

Some browser events require a synchronous decision (allow/deny) before the browser can proceed — file downloads, permission prompts, certificate errors, auth dialogs. CEF provides callback objects for these that can be held and called from any thread.

**Flow:**

```
CEF IO thread:    OnBeforeDownload fires
Main thread:      hold CefBeforeDownloadCallback under callback_id
                  push EventNotification{ needs_resolve=true, callback_id } to session inbox
                  return (do NOT call callback->Continue yet)
                        ↓  inbox
Worker thread:    receives EventNotification (during wait or at loop top)
                  LLM processes it, calls ResolveSyncEvent{ callback_id, allow=true/false }
                  ResolveSyncEvent is CEF-dispatched → CefPostTask
                        ↓  CefPostTask
Main thread:      look up callback by callback_id
                  call callback->Continue(allow, save_path)
                  clean up callback map entry
```

**Timeout:** A watchdog timer on the main thread (e.g. 30s) auto-resolves with a safe default (allow for downloads, deny for permissions) and pushes an `EventNotification` marking the timeout, so the agent is aware it was preempted.

**Callback map** lives in `SessionManager` (or `BrowserActionDispatcher` in Phase 3):
```cpp
std::unordered_map<std::string, CefRefPtr<CefBeforeDownloadCallback>> pending_download_callbacks_;
```

---

## Wait Strategy and Load Verification

### Where waiting happens

Waiting always happens **in the worker thread**. The main thread must never block. Tools that wait either sleep inline (worker-local) or dispatch to the main thread and block `wait_for_tool_result()`.

| Scenario | Tool | Mechanism |
|---|---|---|
| Fixed delay | `Sleep { 500 }` | Worker: `std::this_thread::sleep_for` |
| Wait for page load | `NavigateTo` | Main thread: holds result until `OnLoadEnd` fires |
| Wait for SPA element | `NavigateTo { wait_for_selector }` | Main thread: `OnLoadEnd` + polls `InjectJS` |
| Wait for arbitrary condition | `WaitForCondition` | Worker: loop dispatching `InjectJS` every N ms |
| Wait for event | `SubscribeToEvent` | Worker: blocks on inbox until `EventNotification` arrives |

### Load → Wait → Verify

Keep these as **separate tool calls**. Do not wrap them into a composite "super tool."

Rationale: the LLM sees each intermediate result and can adapt. Composite tools hide failure modes and prevent the agent from recovering gracefully (e.g. the page loaded but to an error page — the agent should see that before deciding to verify).

**Typical page automation flow:**

```
Turn 1:  navigate_to_url { url, wait_for_selector: ".product-list" }
         → one tool call, returns when list is rendered
Turn 2:  inject_js { "return document.querySelectorAll('.product').length" }
         → verify expected content is present
```

For most pages: 2 tool calls, not 3. The "wait" is baked into `NavigateTo`.

For pages that need extra time beyond `OnLoadEnd` and a known selector:

```
Turn 1:  navigate_to_url { url }
         → returns on OnLoadEnd
Turn 2:  wait_for_condition { js_expr: "window.__appReady === true", timeout_ms: 10000 }
         → polls until app signals readiness
Turn 3:  inject_js { verification script }
```

**Never add artificial fixed sleeps when a condition-based wait is possible.** Fixed sleeps are fragile and slow. Reserve `Sleep` for cases like "wait for an animation to finish" where there is no observable DOM condition to poll.

---

## Agent Loop (Worker Thread)

The loop runs entirely on the worker thread. All blocking is done here; the UI thread is never blocked.

### Interrupt Handling

The inbox is the interrupt buffer. Regardless of what the worker is doing, the main thread can always `inbox.enqueue()` without blocking. The worker drains it at the right time for each phase.

```
Phase                  │ UserInput / EventNotification │ CancelSignal
───────────────────────┼───────────────────────────────┼──────────────────────────────
API streaming          │ queue in inbox; flushed next   │ cancel_requested atomic flag;
(blocking HTTP call)   │ turn — LLM finishes current    │ streaming callback checks it
                       │ generation first               │ between chunks → aborts early
───────────────────────┼───────────────────────────────┼──────────────────────────────
Tool wait              │ stashed in deferred{}; flushed │ wait_for_tool_result() throws
(wait_for_tool_result) │ to context at loop top after   │ CancelledError immediately
                       │ tool returns                   │
───────────────────────┼───────────────────────────────┼──────────────────────────────
Between turns          │ try_dequeue() drains all;      │ detected in try_dequeue()
(loop top drain)       │ written to context before      │ loop → returns immediately
                       │ next API call                  │
```

**Why UserInput during streaming isn't discarded:** it queues in the inbox, is stashed into `deferred.user_inputs` at loop top after streaming finishes, and is written to context before the next API call. The LLM sees it on the very next turn. The UX implication is that the agent finishes generating its current response before incorporating the new message — consistent with how chat interfaces work.

**The two-step cancel mechanism:**
`Session::cancel()` does both in order:
```cpp
cancel_requested.store(true);  // 1. abort streaming callback between chunks
inbox.enqueue(CancelSignal{});  // 2. wake up wait_for_tool_result() if blocking
worker_thread.join();
```
Both are needed because the worker is in one of two blocking states at any time: inside the HTTP streaming call (needs the atomic), or inside `inbox.wait_dequeue_timed()` (needs the enqueued signal).

**`needs_resolve` events during streaming:** a sync-blocking event (e.g. download intercept) that arrives while the LLM is generating is handled by the main thread's watchdog timer. The watchdog auto-resolves after N seconds with a safe default and pushes an `EventNotification` with `timed_out=true` to the inbox. When the LLM finishes and the loop top flushes the inbox, the agent sees it as a regular event — it just learns the decision was made on its behalf.

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
struct DeferredItems {
    std::vector<UserInput>           user_inputs;
    std::vector<EventNotification>   notifications;  // async events that arrived mid-wait
};

ToolResult wait_for_tool_result(const std::string& expected_req_id,
                                DeferredItems& deferred) {
    while (true) {
        InboxMessage msg;
        bool got = inbox.wait_dequeue_timed(msg, std::chrono::seconds(120));

        if (!got) throw ToolTimeoutError{expected_req_id};

        if (std::holds_alternative<CancelSignal>(msg))
            throw CancelledError{};

        if (auto* input = std::get_if<UserInput>(&msg)) {
            deferred.user_inputs.push_back(std::move(*input));
            continue;
        }
        if (auto* ev = std::get_if<EventNotification>(&msg)) {
            deferred.notifications.push_back(std::move(*ev));
            continue;
        }
        if (auto* result = std::get_if<ToolResult>(&msg)) {
            if (result->request_id == expected_req_id) return std::move(*result);
            // stale result from a previous subscription — discard
        }
    }
}
```

### Full Loop

```cpp
void Session::run_agent_loop() {
    DeferredItems deferred;

    while (true) {
        // Flush deferred user inputs into context
        for (auto& input : deferred.user_inputs) {
            store->append_user_message(input.text);
        }
        deferred.user_inputs.clear();

        // Flush deferred event notifications into context as tool_result blocks.
        // The LLM sees them as results of the matching subscribe tool_use_id.
        for (auto& ev : deferred.notifications) {
            store->append_event_notification(ev);
            post_display_message(render_event_notification(ev));
        }
        deferred.notifications.clear();

        // 1. Build message array from SQLite context table
        auto messages = store->load_context();

        // 2. Call LLM API — blocking HTTP with streaming.
        //    cancel_requested is checked between every streamed chunk so the
        //    worker can abort a long-running API call without waiting for the
        //    full response.  UserInput and EventNotification that arrive during
        //    streaming simply queue in the inbox and are flushed next turn.
        std::string text_accumulator;
        auto response = llm_client_->complete(messages, tools_,
            [&](Delta delta) {
                if (cancel_requested_.load(std::memory_order_relaxed))
                    throw CancelledError{};
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
                        auto result = wait_for_tool_result(req_id, deferred);
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

        // Drain inbox between turns (non-blocking).
        // EventNotifications and UserInputs are stashed for the next iteration.
        InboxMessage msg;
        while (inbox.try_dequeue(msg)) {
            if (std::holds_alternative<UserInput>(msg)) {
                deferred.user_inputs.push_back(std::get<UserInput>(std::move(msg)));
            } else if (std::holds_alternative<EventNotification>(msg)) {
                deferred.notifications.push_back(std::get<EventNotification>(std::move(msg)));
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
struct NavigateTo {
    std::string tab_id;
    std::string url;
    std::string wait_for_selector = "";   // if set, also waits for this selector post-OnLoadEnd
    int         selector_timeout_ms = 5000;
};
struct InjectJS       { std::string tab_id; std::string script; };  // returns JSON result
struct TakeScreenshot { std::string tab_id; };                       // returns file path to PNG
struct ReadDOM        { std::string tab_id; std::string selector; };
struct SimulateClick  { std::string tab_id; int x; int y; int button = 0; };  // 0=left 1=right 2=mid
struct SimulateKey    { std::string tab_id; std::string key; std::string modifiers; };
struct TypeText       { std::string tab_id; std::string text; };
struct ScrollPage     { std::string tab_id; int delta_x; int delta_y; };
struct GetElementRect { std::string tab_id; std::string selector; };  // returns DOMRect as JSON
struct ReadConsoleLog { std::string tab_id; };  // Phase 6 — CefDevToolsMessageObserver ring buffer
struct OpenNewTab     { std::string initial_url; };   // result arrives via TabAllocated inbox msg
struct CloseTab       { std::string tab_id; };
struct FocusTab       { std::string tab_id; };
// Subscription tools (return subscription_id in ToolResult; then fire EventNotifications)
struct SubscribeToEvent   { std::string tab_id; std::string event_type; std::string filter; };
struct UnsubscribeFromEvent { std::string subscription_id; };

// Worker-local actions — no dispatch needed
struct Sleep            { int duration_ms; };
struct WaitForCondition {
    std::string tab_id;
    std::string js_expr;
    int         timeout_ms       = 10000;
    int         poll_interval_ms = 500;
};
struct ResolveSyncEvent { std::string callback_id; bool allow; std::string params; };
struct CreateCronJob    { std::string schedule; std::string prompt; std::string model; };
struct DeleteCronJob    { std::string cron_id; };
struct ListCronJobs     { };

using BrowserAction = std::variant<
    NavigateTo, InjectJS, TakeScreenshot, ReadDOM,
    SimulateClick, SimulateKey, TypeText, ScrollPage,
    GetElementRect, ReadConsoleLog,
    OpenNewTab, CloseTab, FocusTab,
    SubscribeToEvent, UnsubscribeFromEvent
    // Worker-local tools are NOT in BrowserAction — they bypass the dispatcher
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

## Planning Mode

### Why planning mode

The agent loop is LLM-driven: every turn, the model reads the full context and decides the next tool call. This is powerful for open-ended tasks — but for *repetitive* tasks it is massively wasteful. To scrape 10,000 product pages you do not want to ask the LLM "how do I scrape?" 10,000 times. You want to ask once, get a procedure, and execute that procedure 10,000 times — cheaply and deterministically, falling back to the LLM only when something breaks.

Planning mode separates the two concerns:

| | Agent loop | Plan executor |
|---|---|---|
| LLM calls | Every turn | Once at plan creation; zero during execution |
| Execution | Non-deterministic, adaptive | Deterministic, scripted |
| Speed | Slow (API latency per step) | Fast (no LLM calls at all) |
| Use case | Open-ended tasks, exploration | Repetitive tasks, scheduled jobs |

A **plan** is the artifact that bridges them: a state machine whose nodes were pre-generated by the LLM. The executor runs the state machine without any LLM calls. When the plan fails, `PlanResult{success=false}` is returned to the agent loop — the LLM there decides what to do: revise the plan, retry, escalate to the user, or give up. The executor never attempts recovery on its own, because a failure may not be recoverable by plan revision (e.g., being rate-limited or blocked by the target server).

---

### The "dual loop" — it's just nested calls, not two threads

The user worker thread runs ONE loop at a time. The relationship is:

```
run_agent_loop()
    │
    │  agent calls execute_plan() tool
    ▼
run_plan_executor()          ← pure execution, no LLM calls
    │
    │  each node: post_browser_action() + wait_for_tool_result()
    │  node failure → node's on_failure path (another node or terminal)
    │
    ▼  terminal node reached (success or failure)
back to run_agent_loop()     ← execute_plan tool returns PlanResult
    │
    │  LLM sees PlanResult{success=false, failed_node, error}
    │  and decides: revise the plan? retry? ask the user? give up?
    ▼
```

`run_plan_executor()` is a **worker-local function** called directly from `execute_local_tool()`. It is not a separate thread. It reuses `post_browser_action()`, `wait_for_tool_result()`, and `DeferredItems` exactly as the agent loop does. The "dual loop" is just two nested while() loops on the same thread — the inner loop exits and returns control to the outer loop when the plan reaches a terminal node.

```
Worker thread call stack (simplified):

run_agent_loop()
  while (true) {
    llm.complete(...)                ← LLM decides to call execute_plan()
    execute_local_tool("execute_plan")
      run_plan_executor(plan, inputs)
        while (node != terminal) {
          post_browser_action(...)
          wait_for_tool_result(...)   ← same inbox/deferred machinery
          advance to on_success or on_failure node
        }
        return PlanResult{success, outputs, failed_node, error}
      return ToolResult{plan_result_json}
    store->append_tool_result(...)
    // LLM sees the result and reasons about next step — no special mode
  }
```

No mode flag, no separate state machine thread, no shared mutable state between loops. The executor never calls the LLM.

---

### Plan data structures

```cpp
// A single tool call pre-generated by the LLM during planning.
// args_json may contain template expressions: {{input.url}}, {{node.extract.price}}
struct PlannedAction {
  std::string tool_name;
  std::string args_json_template;
};

// One node in the state machine.
struct PlanNode {
  std::string                id;
  std::string                description;
  std::vector<PlannedAction> actions;     // executed in order
  std::string                on_success;  // id of next node on all actions succeeding
  std::string                on_failure;  // id of next node on any action failing
                                          // "" means terminal failure — return to agent loop
  std::string                output_key;  // if set, store last action result under this key
  int                        max_retries = 0;  // mechanical retries before taking on_failure
};

// A complete plan (state machine).
struct PlanDefinition {
  std::string                              plan_id;
  std::string                              description;
  std::string                              start_node;
  std::unordered_map<std::string, PlanNode> nodes;
  // Serialized to/from JSON; stored in SQLite plans table.
};

// Runtime state during a single plan execution.
struct PlanExecutionContext {
  nlohmann::json inputs;        // substituted for {{input.*}} templates
  nlohmann::json node_outputs;  // node_outputs["node_id"] = last action payload
};

// Returned by run_plan_executor() to the agent loop.
struct PlanResult {
  bool           success;
  nlohmann::json outputs;      // accumulated node byproducts
  std::string    failed_node;  // set on failure
  std::string    error;
};
```

---

### How the LLM creates a plan

A special worker-local tool `CreatePlan` triggers a dedicated planning sub-call:

```
Agent calls create_plan({ "task_description": "Scrape product price from any product page" })
  → execute_local_tool calls make_plan(session, task_description)
    → builds a "planning" system prompt explaining the state machine format
    → calls llm.complete() with a create_plan_definition tool
    → LLM returns a PlanDefinition JSON
    → store->upsert_plan(plan)          // persist to SQLite plans table
    → return ToolResult { plan_id }     // agent now knows the plan_id
```

The agent then calls `execute_plan({ plan_id, inputs })` to run it. The two steps can be chained in one turn or separated — the agent decides.

The planning sub-call uses a focused system prompt (not the full browser context) because planning is a structured output task, not a browsing task:

```
You are designing a browser automation plan. A plan is a state machine where each
node is a sequence of browser tool calls. The plan must be deterministic: no loops
that depend on LLM reasoning, only branching based on tool call success/failure.
Parameterize dynamic values as {{input.key}}. Output using the create_plan tool.
```

---

### Template variable substitution

Before dispatching a `PlannedAction`, the executor substitutes template variables:

```
{{input.url}}          → PlanExecutionContext.inputs["url"]
{{node.extract.price}} → PlanExecutionContext.node_outputs["extract"]["price"]
```

Substitution is a simple string replace before JSON parsing. Template errors (missing key) are treated as node failure → triggers the on_failure path.

---

### Cancellation and infinite-loop protection

The executor runs on the same worker thread as the agent loop, so it holds the thread for its entire duration. Two guards are needed:

**1. Between-node inbox drain (non-blocking)**

After every node transition — whether the node dispatched a browser action or was worker-local — the executor does a non-blocking `try_dequeue` loop over the inbox:

```cpp
InboxMessage msg;
while (session.inbox.try_dequeue(msg)) {
    if (std::holds_alternative<CancelSignal>(msg))
        return PlanResult{.success=false, .error="cancelled"};
    if (auto* u = std::get_if<UserInput>(&msg))
        deferred.user_inputs.push_back(std::move(*u));
    if (auto* ev = std::get_if<EventNotification>(&msg))
        deferred.notifications.push_back(std::move(*ev));
}
if (session.cancel_requested.load(std::memory_order_relaxed))
    return PlanResult{.success=false, .error="cancelled"};
```

`CancelSignal` exits immediately. `UserInput` and `EventNotification` are stashed into the same `DeferredItems` that gets flushed when control returns to the agent loop. Browser actions already handle `CancelSignal` inside `wait_for_tool_result()` — this covers the between-node moment that was previously unguarded.

This drain takes ~10 µs when the inbox is empty (a single failed `try_dequeue`). It is not a "yield to the agent loop" — the LLM is not called. The agent loop only resumes when `run_plan_executor()` returns, which is correct: the plan is logically one tool call.

**Why not a separate thread for the executor?**
A dedicated executor thread would create two consumers on `session.inbox`, breaking the SPSC assumption and requiring a mutex. It also adds a new synchronization channel for node-complete signals back to the worker thread. The one-consumer model is simple and sufficient; the inbox drain solves the cancellation problem without any of that.

**2. Maximum step guard**

If the LLM generates a plan with a cycle, the executor would loop forever. A hard cap prevents this:

```cpp
constexpr int kMaxPlanSteps = 500;
int steps = 0;
while (!is_terminal(current_node_id)) {
    if (++steps > kMaxPlanSteps)
        return PlanResult{.success=false,
                          .error="plan exceeded 500 steps — possible cycle in plan graph"};
    // execute node...
}
```

500 steps is generous for any real task. The error is returned as a `ToolResult` to the agent loop, which can report it to the user.

---

### Failure handling

The executor has no recovery logic. When a node fails:

1. It follows the `on_failure` edge to the next node (which may be a dedicated error-handling node, e.g. one that captures a screenshot of the failure state).
2. If `on_failure` is empty, execution stops immediately and `PlanResult{success=false, failed_node, error}` is returned to the agent loop.

The agent loop LLM then sees the result and reasons about the failure. It may:
- Call `execute_plan` again (retry the whole plan, perhaps on a different input)
- Call `create_plan` to generate a revised plan and execute that
- Use regular agent loop tools to investigate and recover (e.g., navigate away, wait, try again)
- Ask the user what to do
- Give up and mark the task failed

This is the right place to make this judgment. Whether a failure is recoverable — rate-limited server, changed DOM structure, network error, auth required — requires context the executor does not have. The LLM has the full session history and can reason about it.

---

### Plan persistence

New SQLite table (Migration 3):

```sql
CREATE TABLE plans (
  plan_id     TEXT PRIMARY KEY,
  description TEXT NOT NULL,
  definition  TEXT NOT NULL,   -- JSON of PlanDefinition
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER,         -- set when agent calls create_plan to replace this plan
  run_count   INTEGER NOT NULL DEFAULT 0,
  fail_count  INTEGER NOT NULL DEFAULT 0
);
```

When the agent revises a plan after a failure, it calls `create_plan` again (producing a new `plan_id`) or `update_plan` (patching the existing definition). The executor is never involved in this — it simply ran, failed, and returned. The decision to revise is entirely the agent's.

A `plan_run_log` table (optional, Phase 8) can record per-execution outcomes for debugging.

---

### New tools for planning mode

```cpp
// Worker-local tools — no CEF dispatch needed
struct CreatePlan {
  std::string task_description;   // natural language description of the task
  std::string input_schema_json;  // optional JSON Schema describing plan inputs
};

struct ExecutePlan {
  std::string plan_id;
  std::string inputs_json;   // JSON object matching the plan's input schema
};

struct ListPlans {};

struct DeletePlan { std::string plan_id; };
```

`CreatePlan` and `ExecutePlan` are both `DispatchCategory::WorkerLocal` — they run inline on the worker thread.

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

### Cron jobs with plans

A cron job can reference a `plan_id` instead of a plain prompt. When it fires, the session skips the agent loop entirely and runs `run_plan_executor()` directly — no LLM call at all on the happy path:

```json
{
  "cron_id": "daily-price-scrape",
  "schedule": "0 8 * * *",
  "plan_id": "scrape-product-prices",
  "inputs_json": "{\"url\": \"https://example.com/product\"}",
  "model": "claude-opus-4-6"
}
```

A prompt-only cron job (no plan) starts a full agent loop session as before:

```json
{
  "cron_id": "daily-news",
  "schedule": "0 8 * * *",
  "prompt": "Open HN and summarize the top 5 posts",
  "model": "claude-opus-4-6"
}
```

The session mode is determined at startup by whether `plan_id` is set. `TriggerType` gains a `CronPlan` value alongside the existing `Cron` and `UserPrompt`.

The practical workflow is: user prompts the agent to scrape something → agent runs it once interactively → agent calls `create_plan` to formalize what it did → agent calls `create_cron_job` referencing the plan → future runs are fast and LLM-free.


---

## Crash Recovery

### The invariant: context is always in a consistent state

The worker writes the full assistant message (including all `tool_use` blocks) to `context` atomically in a single SQLite transaction **after** the stream ends, never mid-stream. This means the context table is always at a clean message boundary — no partial writes to recover from.

The only inconsistent state possible is: **assistant message written, but its `tool_result`(s) not yet written** (i.e. the app was killed while a tool was in-flight). This is the case we need to detect and repair.

### Tracking in-flight tool calls: `pending_tool_calls`

A dedicated table tracks exactly which tool calls are currently awaiting results:

```sql
-- Rows are inserted when a tool is dispatched, deleted when the result arrives.
-- Any rows present at startup = interrupted in-flight calls.
CREATE TABLE pending_tool_calls (
    tool_use_id   TEXT PRIMARY KEY,   -- Claude's tool_use block id (from API response)
    request_id    TEXT NOT NULL,      -- our BrowserActionRequest UUID
    tool_name     TEXT NOT NULL,
    args_json     TEXT NOT NULL,
    dispatched_at INTEGER NOT NULL
);
```

Worker lifecycle per tool call:
```cpp
// Before dispatching:
store->insert_pending_tool_call(tool_use_id, req_id, tool_name, args_json);
post_browser_action(req_id, tool_call);

// After result arrives:
store->delete_pending_tool_call(tool_use_id);
store->append_tool_result(tool_use_id, result);
```

### Recovery on app restart

On startup, `SessionManager::restore_sessions()` scans `~/.openclam/sessions/` for sessions in non-terminal states and applies one of three recovery paths:

**Path A — `status = waiting_for_tool` (crashed during tool execution)**

```
pending_tool_calls has rows → in-flight calls need synthetic results

For each row in pending_tool_calls:
  1. Inject synthetic tool_result into context:
       { "error": "App restarted while this tool was executing. Result unknown." }
  2. Write to chat_history as a system message so the user sees it
  3. Delete from pending_tool_calls

Set status = running
Offer to user: "Session X was interrupted — resume?"
If yes: restart worker thread (it will re-call the LLM with the injected failures)
```

The agent receives the failure results on the next API call. It knows what was attempted (from its own prior tool_use blocks) and decides whether to retry, navigate away, or ask the user. This is the right place to make that decision.

**Path B — `status = running` (crashed mid-streaming)**

The context table ends cleanly at the last complete message (no partial assistant turn). `pending_tool_calls` is empty. No injection needed. Just restart the worker — it calls `store->load_context()` and re-calls the LLM from the clean state.

**Path C — `status = waiting_for_user`**

Worker was not running. Context and chat_history are clean. Show history in the chat panel; the session resumes when the user sends input.

### LLM API timeout

No tool was dispatched, so `pending_tool_calls` is empty and context is clean. The worker retries with exponential backoff (see API Shim section). After N retries:
- Mark session `Failed`, persist diagnostic to `session_meta.status_detail`
- Do NOT inject anything into context — the last user message stands
- On manual restart, the user can try again; the session resumes from the clean state

### Browser event handling timeout (sync-blocking watchdog)

Not a session failure. The main thread auto-resolves the held CEF callback with a safe default, then pushes:
```cpp
EventNotification { needs_resolve=false, timed_out=true, callback_id, ... }
```
The session continues normally. The agent is informed on the next turn and decides whether to retry the triggering action. Only if the agent itself gives up does the session fail.

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

### Phase 1 — Core Infrastructure ✅

**Goal:** Session objects exist, can be created/destroyed, SQLite files are managed.

- [x] `SessionStore` class: open/create SQLite file, WAL mode, schema migration
- [x] `Session` class: fields, status enum, lock-free inbox (`moodycamel::BlockingConcurrentQueue`)
- [x] `SessionManager` class: create/destroy/find sessions, no agent logic yet
- [x] Tab allocation: `AllocateTabRequest` flow — main thread creates a `BrowserTabMac`, assigns a tab ID, enqueues `TabAllocated`
- [x] Session ID and tab ID generation utilities
- [x] Persist tab list and session metadata to SQLite on every change
- [x] CMake: `FetchContent` for concurrentqueue; system sqlite3 linked

**Deliverable:** `SessionManager::create_session()` creates a session with one tab, persists to disk, and can be destroyed cleanly. ✅

---

### Phase 2 — Agent Loop Skeleton ✅

**Goal:** Worker thread runs a loop, can receive messages, shuts down cleanly.

- [x] `Session::start()` spawns worker thread running `run_agent_loop()`
- [x] `wait_for_tool_result()` inner loop with `DeferredItems` stashing
- [x] Post helpers: `post_display()`, `post_status()`, `post_browser_action()` in `agent_loop.cc`
- [x] Main thread `on_session_message()` dispatcher: routes all `OutboundMessage` variants to handlers
- [x] `handle_display_message()`: stub logs to stderr; Phase 5 will forward to Vue panel
- [x] `handle_browser_action()`: stub enqueues dummy `ToolResult` immediately; Phase 3 replaces with real CEF dispatch
- [x] `Session::cancel()`: sets `cancel_requested` flag, enqueues `CancelSignal`, joins worker thread
- [x] `EventNotification` added to `InboxMessage` variant; stashed in `DeferredItems` during tool wait
- [x] `OutboundFn` callback on `Session` decouples worker from CEF; `SessionManager::start_session()` wires it up

**Note on threading:** In Phase 2 the `OutboundFn` calls `on_session_message()` directly from the worker thread. This is safe for the stub because `handle_browser_action` only touches `session.inbox.enqueue()` (thread-safe) and `handle_status_update` does a plain assignment to `session.status` (worker is the sole writer). Phase 5 will replace the lambda body with `CefPostTask(TID_UI, ...)` to make all main-thread operations happen on the UI thread.

**Deliverable:** Worker thread loops, posts stub messages, handles interleaved `UserInput` and `EventNotification` during tool waits, shuts down cleanly on cancel. Stub browser action dispatcher returns immediately. No real Claude calls yet. ✅

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
