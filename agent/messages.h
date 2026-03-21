#pragma once

#include <string>
#include <variant>
#include <cstdint>

#include "agent/types.h"

// ==========================================================================
// Browser action structs
//
// tab_id is embedded in each struct so the dispatcher receives a
// self-contained request.  Worker-local actions (CreateCronJob, etc.) do not
// appear here — they are handled directly on the worker thread without going
// through the main thread dispatcher.
// ==========================================================================

struct NavigateTo {
  std::string tab_id;
  std::string url;
  std::string wait_for_selector = "";   // poll for this CSS selector after OnLoadEnd
  int         selector_timeout_ms = 5000;
};
struct InjectJS       { std::string tab_id; std::string script; };
struct TakeScreenshot { std::string tab_id; };
struct ReadDOM        { std::string tab_id; std::string selector; };
struct SimulateClick  { std::string tab_id; int x; int y; int button; };  // button: 0=left 1=right 2=middle
struct SimulateKey    { std::string tab_id; std::string key; std::string modifiers; };
struct TypeText       { std::string tab_id; std::string text; };
struct ScrollPage     { std::string tab_id; int delta_x; int delta_y; };
struct GetElementRect { std::string tab_id; std::string selector; };
struct ReadConsoleLog { std::string tab_id; };
struct OpenNewTab     { std::string initial_url; };
struct CloseTab       { std::string tab_id; };
struct FocusTab       { std::string tab_id; };

// Subscription tools — result is a subscription_id; then EventNotifications arrive.
struct SubscribeToEvent   { std::string tab_id; std::string event_type; std::string filter; };
struct UnsubscribeFromEvent { std::string subscription_id; };

using BrowserAction = std::variant<
    NavigateTo,
    InjectJS,
    TakeScreenshot,
    ReadDOM,
    SimulateClick,
    SimulateKey,
    TypeText,
    ScrollPage,
    GetElementRect,
    ReadConsoleLog,
    OpenNewTab,
    CloseTab,
    FocusTab,
    SubscribeToEvent,
    UnsubscribeFromEvent
>;

// ==========================================================================
// Outbound messages  (worker thread → main thread, via CefPostTask)
// ==========================================================================

// Render a text chunk or a tool call/result summary in the chat panel.
struct DisplayMessage {
  std::string role;         // "assistant" | "tool_call" | "tool_result"
  std::string text;
  bool        is_thinking  = false;
  bool        is_streaming = false;   // true while streaming, false on final chunk
  int64_t     timestamp_ms = 0;
};

// Request a CEF browser action.  The dispatcher executes it on the main
// thread and pushes a ToolResult into the session inbox when done.
struct BrowserActionRequest {
  std::string   request_id;   // UUID — echoed back in ToolResult
  std::string   session_id;
  BrowserAction action;
};

// Notify the main thread of a session status change.
struct SessionStatusUpdate {
  SessionStatus new_status;
  std::string   detail;       // error message when Failed
};

// Request the main thread to create a new BrowserTabMac and return its
// agent tab_id via a TabAllocated inbox message.
struct AllocateTabRequest {
  std::string request_id;
  std::string session_id;
  std::string initial_url;
};

// Tell the main thread to reload the cron scheduler from crons.json.
// Sent after CreateCronJob / DeleteCronJob worker-local tool calls.
struct ReloadCronSchedule {};

using OutboundMessage = std::variant<
    DisplayMessage,
    BrowserActionRequest,
    SessionStatusUpdate,
    AllocateTabRequest,
    ReloadCronSchedule
>;

// ==========================================================================
// Inbox messages  (main thread → worker thread, via session.inbox)
// ==========================================================================

// Result of a BrowserActionRequest.  request_id matches the outbound request.
struct ToolResult {
  std::string request_id;
  bool        success = true;
  std::string payload;      // JSON string; for screenshots, a file path
};

// A new user message typed in the chat panel.
struct UserInput {
  std::string text;
};

// Confirmation that a new tab was allocated.  Sent in response to
// AllocateTabRequest or as the result of an OpenNewTab browser action.
struct TabAllocated {
  std::string request_id;   // matches AllocateTabRequest::request_id
  std::string tab_id;       // newly assigned agent tab ID
};

// Graceful shutdown signal.  Worker must exit its loop upon receiving this.
struct CancelSignal {};

// Fired by the main thread when a browser event occurs on a subscribed tab.
// For sync-blocking events (needs_resolve=true) the worker must call
// ResolveSyncEvent{ callback_id } within the watchdog timeout, or the main
// thread auto-resolves and pushes another notification with timed_out=true.
struct EventNotification {
  std::string subscription_id;  // returned by SubscribeToEvent ToolResult
  std::string event_type;       // "mutation" | "console_error" | "network_request" | "download"
  std::string payload;          // JSON event data
  bool        needs_resolve = false;  // true for intercept-and-hold events
  bool        timed_out     = false;  // true when watchdog auto-resolved
  std::string callback_id;            // non-empty when needs_resolve=true
};

using InboxMessage = std::variant<
    ToolResult,
    UserInput,
    TabAllocated,
    CancelSignal,
    EventNotification
>;
