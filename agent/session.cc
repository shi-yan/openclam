#include "agent/session.h"

#include <cstdio>

#include "agent/agent_loop.h"

Session::Session(std::string id, TriggerType trig, std::string mdl)
    : session_id(std::move(id)),
      trigger(trig),
      model(std::move(mdl)) {}

Session::~Session() {
  // Ensure the worker thread is not left running if the session is destroyed
  // without an explicit cancel() call.
  cancel();
}

void Session::start() {
  worker_thread = std::thread([this] { run_agent_loop(*this); });
}

void Session::cancel() {
  // Set the flag first so the streaming callback sees it between chunks,
  // then enqueue the signal so the tool-wait inner loop exits immediately.
  cancel_requested.store(true, std::memory_order_relaxed);
  if (worker_thread.joinable()) {
    inbox.enqueue(CancelSignal{});
    worker_thread.join();
  }
}
