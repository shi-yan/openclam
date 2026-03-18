#pragma once

#include <string>
#include <vector>

#include "agent/messages.h"

class Session;

// ---------------------------------------------------------------------------
// DeferredItems
//
// Holds inbox messages that arrived while the worker was blocked in
// wait_for_tool_result().  They are flushed into context at the top of the
// next agent loop iteration so the LLM sees them on the next turn.
// ---------------------------------------------------------------------------
struct DeferredItems {
  std::vector<UserInput>         user_inputs;
  std::vector<EventNotification> notifications;
};

// ---------------------------------------------------------------------------
// WaitResult
//
// Returned by wait_for_tool_result().  No exceptions (CEF build uses
// -fno-exceptions), so errors are expressed as a status enum.
// ---------------------------------------------------------------------------
enum class WaitStatus {
  Ok,        // result->request_id matched expected_req_id
  Cancelled, // CancelSignal received
  TimedOut,  // inbox.wait_dequeue_timed() expired (120 s default)
};

struct WaitResult {
  WaitStatus status = WaitStatus::Ok;
  ToolResult result;  // valid only when status == Ok
};

// ---------------------------------------------------------------------------
// wait_for_tool_result
//
// Blocks the worker thread until a ToolResult with the given request_id
// arrives in session.inbox.  Other inbox message types are handled as:
//   - UserInput / EventNotification → stashed in deferred (flushed next turn)
//   - TabAllocated                  → discarded (unexpected mid-tool-wait)
//   - CancelSignal                  → returns Cancelled immediately
//   - ToolResult with wrong id      → discarded (stale from previous dispatch)
// ---------------------------------------------------------------------------
WaitResult wait_for_tool_result(Session&           session,
                                const std::string& expected_req_id,
                                DeferredItems&     deferred);

// ---------------------------------------------------------------------------
// run_agent_loop
//
// Entry point for the session worker thread.  Called by Session::start().
// Loops until the task is complete, the session is cancelled, or a fatal
// error occurs.  Posts all outbound messages via session.outbound_fn.
//
// Phase 4 will replace the stub LLM call with a real AnthropicClient call.
// Phase 4 will replace the stub tool dispatch with real BrowserAction calls.
// ---------------------------------------------------------------------------
void run_agent_loop(Session& session);
