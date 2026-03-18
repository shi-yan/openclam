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

        if constexpr (std::is_same_v<T, AllocateTabRequest>) {
          handle_allocate_tab(session, std::move(m));
        } else if constexpr (std::is_same_v<T, SessionStatusUpdate>) {
          handle_status_update(session, std::move(m));
        } else if constexpr (std::is_same_v<T, ReloadCronSchedule>) {
          // Phase 6: reload cron scheduler here.
          std::fprintf(stderr, "[SessionManager] ReloadCronSchedule (stub)\n");
        } else {
          // DisplayMessage and BrowserActionRequest are handled in Phase 2/3.
          // Log them as stubs so their arrival is visible during development.
          std::fprintf(stderr,
                       "[SessionManager] unhandled outbound message type"
                       " from session %s (Phase 2/3 stub)\n",
                       session_id.c_str());
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
