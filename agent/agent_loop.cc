#include "agent/agent_loop.h"

#include <chrono>
#include <cstdio>
#include <variant>

#include "agent/id_utils.h"
#include "agent/session.h"

// ---------------------------------------------------------------------------
// Helpers — post outbound messages from the worker thread
// ---------------------------------------------------------------------------

namespace {

void post(Session& s, OutboundMessage msg) {
  s.outbound_fn(std::move(msg));
}

void post_status(Session& s, SessionStatus st, const std::string& detail = "") {
  post(s, SessionStatusUpdate{st, detail});
}

void post_display(Session& s, const std::string& role,
                  const std::string& text, bool is_streaming = false) {
  DisplayMessage dm;
  dm.role         = role;
  dm.text         = text;
  dm.is_streaming = is_streaming;
  dm.timestamp_ms = id_utils::now_ms();
  post(s, std::move(dm));
}

void post_browser_action(Session& s, const std::string& req_id,
                         BrowserAction action) {
  BrowserActionRequest req;
  req.request_id = req_id;
  req.session_id = s.session_id;
  req.action     = std::move(action);
  post(s, std::move(req));
}

}  // namespace

// ---------------------------------------------------------------------------
// wait_for_tool_result
// ---------------------------------------------------------------------------

WaitResult wait_for_tool_result(Session&           session,
                                const std::string& expected_req_id,
                                DeferredItems&     deferred) {
  while (true) {
    InboxMessage msg;
    // Block up to 120 s for the next inbox message.
    bool got = session.inbox.wait_dequeue_timed(
        msg, std::chrono::seconds(120));

    if (!got) {
      return WaitResult{WaitStatus::TimedOut, {}};
    }

    // CancelSignal — abort immediately.
    if (std::holds_alternative<CancelSignal>(msg)) {
      return WaitResult{WaitStatus::Cancelled, {}};
    }

    // UserInput — stash; flush at the top of the next loop iteration.
    if (auto* u = std::get_if<UserInput>(&msg)) {
      deferred.user_inputs.push_back(std::move(*u));
      continue;
    }

    // EventNotification — stash; flushed into context at loop top.
    if (auto* ev = std::get_if<EventNotification>(&msg)) {
      deferred.notifications.push_back(std::move(*ev));
      continue;
    }

    // TabAllocated — not expected during a tool wait; discard.
    if (std::holds_alternative<TabAllocated>(msg)) {
      std::fprintf(stderr,
                   "[AgentLoop] unexpected TabAllocated during tool wait"
                   " (expected req_id=%s) — discarding\n",
                   expected_req_id.c_str());
      continue;
    }

    // ToolResult — check req_id.
    if (auto* result = std::get_if<ToolResult>(&msg)) {
      if (result->request_id == expected_req_id) {
        return WaitResult{WaitStatus::Ok, std::move(*result)};
      }
      // Stale result from a previous (timed-out) dispatch — discard.
      std::fprintf(stderr,
                   "[AgentLoop] discarding stale ToolResult"
                   " (got=%s expected=%s)\n",
                   result->request_id.c_str(), expected_req_id.c_str());
      continue;
    }
  }
}

// ---------------------------------------------------------------------------
// run_agent_loop
//
// Phase 2 stub:  demonstrates the full message-passing skeleton without a
// real LLM or real browser actions.  The stub loop:
//
//   1. Flushes any deferred user inputs by echoing them back.
//   2. Dispatches one stub InjectJS browser action and waits for its result.
//   3. Drains remaining inbox messages (stashing UserInput/EventNotification).
//   4. Loops if there are deferred user inputs to process; otherwise exits.
//
// Phase 4 will replace step 2 with a real LLM API call that returns tool_use
// blocks, and replace the dummy InjectJS with the tool the LLM requested.
// ---------------------------------------------------------------------------

void run_agent_loop(Session& session) {
  std::fprintf(stderr, "[AgentLoop] session %s starting\n",
               session.session_id.c_str());

  post_status(session, SessionStatus::Running);
  post_display(session, "assistant",
               "[Phase 2 stub] Agent loop started. "
               "Real LLM integration comes in Phase 4.");

  DeferredItems deferred;
  bool first_iteration = true;

  while (true) {
    // -----------------------------------------------------------------------
    // Top of loop: flush deferred items accumulated during the previous
    // tool wait (or the initial drain).
    // -----------------------------------------------------------------------
    for (auto& input : deferred.user_inputs) {
      // Phase 4: append to SQLite context and include in next API call.
      // Phase 2 stub: echo back so the outbound channel is exercised.
      post_display(session, "assistant",
                   "[stub echo] " + input.text);
    }
    deferred.user_inputs.clear();

    for (auto& ev : deferred.notifications) {
      // Phase 4: append to SQLite context as a tool_result block.
      // Phase 2 stub: just log.
      std::fprintf(stderr,
                   "[AgentLoop] deferred EventNotification:"
                   " sub=%s type=%s\n",
                   ev.subscription_id.c_str(), ev.event_type.c_str());
    }
    deferred.notifications.clear();

    // -----------------------------------------------------------------------
    // Phase 2 stub "LLM call": dispatch one dummy InjectJS action to exercise
    // the BrowserActionRequest → ToolResult round-trip.  Phase 4 replaces
    // this with a real blocking HTTP call to the LLM API.
    // -----------------------------------------------------------------------
    if (first_iteration) {
      first_iteration = false;

      // Pick the first tab if available.
      std::string tab_id = session.tabs.empty() ? "" : session.tabs[0].tab_id;

      std::string req_id = id_utils::new_uuid();
      post_status(session, SessionStatus::WaitingForTool);
      post_browser_action(session, req_id,
                          InjectJS{tab_id, "return 'stub result from InjectJS'"});

      WaitResult wr = wait_for_tool_result(session, req_id, deferred);

      if (wr.status == WaitStatus::Cancelled) {
        post_status(session, SessionStatus::Cancelled);
        std::fprintf(stderr, "[AgentLoop] session %s cancelled during tool wait\n",
                     session.session_id.c_str());
        return;
      }
      if (wr.status == WaitStatus::TimedOut) {
        post_status(session, SessionStatus::Failed, "tool timed out");
        std::fprintf(stderr, "[AgentLoop] session %s tool timed out\n",
                     session.session_id.c_str());
        return;
      }

      post_status(session, SessionStatus::Running);
      post_display(session, "tool_result",
                   "[stub] browser action result: " + wr.result.payload);
    }

    // -----------------------------------------------------------------------
    // Drain inbox between turns (non-blocking).
    // CancelSignal exits immediately; other messages are stashed for the next
    // iteration.
    // -----------------------------------------------------------------------
    {
      InboxMessage msg;
      while (session.inbox.try_dequeue(msg)) {
        if (std::holds_alternative<CancelSignal>(msg)) {
          post_status(session, SessionStatus::Cancelled);
          std::fprintf(stderr,
                       "[AgentLoop] session %s cancelled between turns\n",
                       session.session_id.c_str());
          return;
        }
        if (auto* u = std::get_if<UserInput>(&msg)) {
          deferred.user_inputs.push_back(std::move(*u));
        } else if (auto* ev = std::get_if<EventNotification>(&msg)) {
          deferred.notifications.push_back(std::move(*ev));
        }
      }
    }

    // If there are deferred user inputs, loop again to echo them.
    // Otherwise the stub task is done.
    if (deferred.user_inputs.empty() && deferred.notifications.empty()) {
      post_status(session, SessionStatus::Completed);
      std::fprintf(stderr, "[AgentLoop] session %s completed\n",
                   session.session_id.c_str());
      return;
    }
  }
}
