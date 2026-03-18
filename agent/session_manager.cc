#include "agent/session_manager.h"

#include <cassert>
#include <cstdio>

#include "agent/id_utils.h"
#include "agent/session.h"
#include "agent/session_store.h"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

namespace {

// Returns the default sessions directory, e.g. ~/.openclam/sessions
std::string sessions_dir() {
  const char* home = ::getenv("HOME");
  std::string base = home ? home : "/tmp";
  return base + "/.openclam/sessions";
}

// Returns the path to a session's SQLite file.
std::string db_path_for(const std::string& session_id) {
  return sessions_dir() + "/" + session_id + "/session.db";
}

}  // namespace

// ---------------------------------------------------------------------------
// SessionManager
// ---------------------------------------------------------------------------

SessionManager::SessionManager() = default;
SessionManager::~SessionManager() = default;

void SessionManager::set_tab_allocator(TabAllocator allocator) {
  tab_allocator_ = std::move(allocator);
}

std::shared_ptr<Session> SessionManager::create_session(
    TriggerType        trigger,
    const std::string& initial_prompt,
    const std::string& model) {

  const std::string sid = id_utils::new_session_id();
  const int64_t     now = id_utils::now_ms();

  // -- Create Session object --
  auto session = std::make_shared<Session>(sid, trigger, model);

  // -- Open SQLite store --
  session->store = std::make_unique<SessionStore>(db_path_for(sid));
  if (!session->store->open()) {
    std::fprintf(stderr,
                 "[SessionManager] failed to open SQLite store for %s\n",
                 sid.c_str());
    return nullptr;
  }

  // -- Persist initial metadata --
  session->store->set_meta("session_id",    sid);
  session->store->set_meta("status",        to_string(session->status));
  session->store->set_meta("trigger_type",  to_string(trigger));
  session->store->set_meta("model",         model);
  session->store->set_meta("created_at",    std::to_string(now));
  session->store->set_meta("initial_prompt", initial_prompt);

  // -- Allocate one initial tab --
  if (tab_allocator_) {
    std::string tab_id = tab_allocator_(sid, /*initial_url=*/"");
    if (tab_id.empty()) {
      std::fprintf(stderr,
                   "[SessionManager] tab_allocator returned empty id for %s\n",
                   sid.c_str());
      // Non-fatal: session is usable, agent can request tabs via
      // AllocateTabRequest once the worker starts.
    } else {
      Tab t;
      t.tab_id    = tab_id;
      t.tab_index = 0;
      session->tabs.push_back(t);
      session->store->upsert_tab(tab_id, "", "", 0);
    }
  }

  sessions_[sid] = session;
  return session;
}

void SessionManager::destroy_session(const std::string& session_id) {
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) return;

  auto& session = *it->second;

  // Stop worker (no-op if not started yet).
  session.cancel();

  // Persist terminal status.
  if (session.store) {
    session.store->set_meta("status", to_string(session.status));
    session.store->set_meta("completed_at",
                            std::to_string(id_utils::now_ms()));
  }

  sessions_.erase(it);
}

std::shared_ptr<Session> SessionManager::find_session(
    const std::string& session_id) const {
  auto it = sessions_.find(session_id);
  return it != sessions_.end() ? it->second : nullptr;
}

// ---------------------------------------------------------------------------
// Message dispatch  (called on main thread via CefPostTask)
// ---------------------------------------------------------------------------

void SessionManager::on_session_message(const std::string& session_id,
                                         OutboundMessage    msg) {
  auto session_ptr = find_session(session_id);
  if (!session_ptr) {
    std::fprintf(stderr,
                 "[SessionManager] on_session_message: unknown session %s\n",
                 session_id.c_str());
    return;
  }
  Session& session = *session_ptr;

  std::visit(
      [&](auto&& m) {
        using T = std::decay_t<decltype(m)>;

        if constexpr (std::is_same_v<T, DisplayMessage>) {
          handle_display_message(session, std::move(m));
        } else if constexpr (std::is_same_v<T, BrowserActionRequest>) {
          handle_browser_action(session, std::move(m));
        } else if constexpr (std::is_same_v<T, AllocateTabRequest>) {
          handle_allocate_tab(session, std::move(m));
        } else if constexpr (std::is_same_v<T, SessionStatusUpdate>) {
          handle_status_update(session, std::move(m));
        } else if constexpr (std::is_same_v<T, ReloadCronSchedule>) {
          // Phase 6: reload cron scheduler here.
          std::fprintf(stderr, "[SessionManager] ReloadCronSchedule (stub)\n");
        }
      },
      std::move(msg));
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

void SessionManager::handle_allocate_tab(Session& session,
                                          AllocateTabRequest req) {
  if (!tab_allocator_) {
    std::fprintf(stderr,
                 "[SessionManager] AllocateTabRequest received but no "
                 "tab_allocator registered\n");
    session.inbox.enqueue(
        TabAllocated{req.request_id, /*tab_id=*/""});
    return;
  }

  std::string tab_id = tab_allocator_(session.session_id, req.initial_url);

  if (!tab_id.empty()) {
    Tab t;
    t.tab_id    = tab_id;
    t.tab_index = static_cast<int>(session.tabs.size());
    session.tabs.push_back(t);

    if (session.store) {
      session.store->upsert_tab(tab_id, req.initial_url, "", t.tab_index);
    }
  }

  session.inbox.enqueue(TabAllocated{req.request_id, tab_id});
}

// ---------------------------------------------------------------------------

void SessionManager::start_session(const std::string& session_id) {
  auto session_ptr = find_session(session_id);
  if (!session_ptr) {
    std::fprintf(stderr,
                 "[SessionManager] start_session: unknown session %s\n",
                 session_id.c_str());
    return;
  }

  // Keep a weak reference so the lambda does not extend the session lifetime.
  std::weak_ptr<Session> weak = session_ptr;

  // Build the outbound callback.  The worker thread calls this for every
  // outbound message.  In Phase 2 we invoke on_session_message() directly
  // from the worker thread — this is safe here because:
  //   - handle_browser_action (stub) only touches session.inbox.enqueue(),
  //     which is thread-safe.
  //   - handle_status_update writes session.status (plain assignment), which
  //     is safe because only the worker writes it.
  //   - handle_display_message (stub) only calls fprintf, which is safe.
  // TODO Phase 5: wrap the body with CefPostTask(TID_UI, ...) so all
  //   on_session_message calls happen on the UI thread in production.
  session_ptr->outbound_fn = [this, session_id](OutboundMessage msg) {
    on_session_message(session_id, std::move(msg));
  };

  session_ptr->start();
}

// ---------------------------------------------------------------------------

void SessionManager::handle_display_message(Session& /*session*/,
                                             DisplayMessage msg) {
  // Phase 5: forward to Vue chat panel via ExecuteJavaScript.
  // Phase 2 stub: log to stderr so the channel is visibly exercised.
  std::fprintf(stderr, "[SessionManager] display[%s%s]: %s\n",
               msg.role.c_str(),
               msg.is_thinking ? "/thinking" : "",
               msg.text.c_str());
}

// ---------------------------------------------------------------------------
// Phase 2 stub browser action dispatcher.
//
// Immediately enqueues a dummy ToolResult so the worker's wait_for_tool_result
// can return.  Phase 3 will replace this with real CEF dispatch.
// ---------------------------------------------------------------------------

void SessionManager::handle_browser_action(Session& session,
                                            BrowserActionRequest req) {
  // Log the incoming action name for visibility.
  const char* action_name = std::visit(
      [](auto&& a) -> const char* {
        using T = std::decay_t<decltype(a)>;
        if constexpr (std::is_same_v<T, NavigateTo>)     return "NavigateTo";
        if constexpr (std::is_same_v<T, InjectJS>)       return "InjectJS";
        if constexpr (std::is_same_v<T, TakeScreenshot>) return "TakeScreenshot";
        if constexpr (std::is_same_v<T, ReadDOM>)        return "ReadDOM";
        if constexpr (std::is_same_v<T, SimulateClick>)  return "SimulateClick";
        if constexpr (std::is_same_v<T, SimulateKey>)    return "SimulateKey";
        if constexpr (std::is_same_v<T, TypeText>)       return "TypeText";
        if constexpr (std::is_same_v<T, ScrollPage>)     return "ScrollPage";
        if constexpr (std::is_same_v<T, GetElementRect>) return "GetElementRect";
        if constexpr (std::is_same_v<T, ReadConsoleLog>) return "ReadConsoleLog";
        if constexpr (std::is_same_v<T, OpenNewTab>)     return "OpenNewTab";
        if constexpr (std::is_same_v<T, CloseTab>)       return "CloseTab";
        if constexpr (std::is_same_v<T, FocusTab>)       return "FocusTab";
        return "Unknown";
      },
      req.action);

  std::fprintf(stderr,
               "[SessionManager] BrowserAction stub: %s req_id=%s\n",
               action_name, req.request_id.c_str());

  // Enqueue a synthetic success result immediately.
  // Phase 3 will replace this with a real CEF call that completes
  // asynchronously and enqueues the result from its completion callback.
  ToolResult result;
  result.request_id = req.request_id;
  result.success    = true;
  result.payload    = "{\"stub\":true,\"action\":\"" +
                      std::string(action_name) + "\"}";
  session.inbox.enqueue(std::move(result));
}

// ---------------------------------------------------------------------------

void SessionManager::handle_status_update(Session& session,
                                           SessionStatusUpdate upd) {
  session.status = upd.new_status;

  if (session.store) {
    session.store->set_meta("status", to_string(upd.new_status));
    if (!upd.detail.empty()) {
      session.store->set_meta("status_detail", upd.detail);
    }
    if (is_terminal(upd.new_status)) {
      session.store->set_meta("completed_at",
                              std::to_string(id_utils::now_ms()));
    }
  }
}
