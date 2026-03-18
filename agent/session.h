#pragma once

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "blockingconcurrentqueue.h"  // moodycamel — added via FetchContent

#include "agent/messages.h"
#include "agent/session_store.h"
#include "agent/types.h"

// ---------------------------------------------------------------------------
// Session
//
// Represents one automation session.  Created and destroyed on the main
// thread.  The worker thread (added in Phase 2) runs the agent loop and
// communicates via:
//
//   Worker → Main : CefPostTask(TID_UI, ...)          — outbound messages
//   Main → Worker : session.inbox.enqueue(...)        — inbound messages
//
// Ownership rules:
//   - The main thread owns all Tab::browser pointers (added in Phase 3).
//   - The worker thread owns the agent loop state.
//   - session_id, trigger, model, and status are set on construction or
//     updated atomically by the worker; the main thread may read them.
// ---------------------------------------------------------------------------
class Session {
 public:
  Session(std::string session_id, TriggerType trigger, std::string model);
  ~Session();

  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;

  // ---- Identity (immutable after construction) ----
  const std::string session_id;
  const TriggerType trigger;
  const std::string model;

  // ---- Status (written by worker, read by main) ----
  // Plain assignment is fine because status transitions always happen on the
  // worker thread and the main thread only reads it for display.
  SessionStatus status = SessionStatus::Created;

  // ---- Tabs (main thread only) ----
  // The worker reads tab_id strings only; it never dereferences browser ptrs.
  std::vector<Tab> tabs;

  // ---- Persistence ----
  std::unique_ptr<SessionStore> store;

  // ---- Inbox: Main → Worker  (lock-free SPSC) ----
  // Producer: main thread.  Consumer: worker thread.
  moodycamel::BlockingConcurrentQueue<InboxMessage> inbox;

  // ---- Cancellation flag ----
  // Set to true by cancel() before enqueuing CancelSignal.
  // The worker's LLM streaming callback polls this between chunks so it can
  // abort a long-running API call without waiting for the stream to finish.
  // Written by main thread, read by worker — std::atomic for safety.
  std::atomic<bool> cancel_requested{false};

  // ---- Worker thread (started in Phase 2) ----
  std::thread worker_thread;

  // Gracefully shut down the session.
  // Sets cancel_requested, enqueues CancelSignal, and joins the worker thread.
  // Safe to call before the worker is started (no-op for the join).
  void cancel();
};
