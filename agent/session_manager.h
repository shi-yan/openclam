#pragma once

#include <functional>
#include <memory>
#include <string>
#include <unordered_map>

#include "agent/messages.h"
#include "agent/types.h"

class Session;

// ---------------------------------------------------------------------------
// SessionManager
//
// Lives on and must only be accessed from the main (UI) thread.
// Owns all live sessions.
//
// Tab creation requires AppKit/CEF and therefore must happen on the main
// thread.  The manager delegates actual BrowserTabMac creation to a
// TabAllocator callback registered by the app at startup.  The callback
// receives the session_id and an optional initial URL; it creates the native
// tab, assigns a string agent tab ID (e.g. "a1b2c3d4-t0"), and returns it.
//
// In Phase 1 the TabAllocator creates a stub Tab record (browser = nullptr).
// In Phase 3 it will create a real BrowserTabMac and store the pointer.
// ---------------------------------------------------------------------------
class SessionManager {
 public:
  SessionManager();
  ~SessionManager();

  SessionManager(const SessionManager&) = delete;
  SessionManager& operator=(const SessionManager&) = delete;

  // Callback type for tab creation.
  // Called on the main thread.
  // Returns the new agent tab_id string, or "" on failure.
  using TabAllocator = std::function<std::string(
      const std::string& session_id,
      const std::string& initial_url)>;

  // Must be called before create_session().
  void set_tab_allocator(TabAllocator allocator);

  // Create a new session, open its SQLite store, allocate one initial tab,
  // and persist metadata.  Returns nullptr on failure.
  // Does NOT start the worker thread — call start_session() after setup.
  std::shared_ptr<Session> create_session(
      TriggerType        trigger,
      const std::string& initial_prompt,
      const std::string& model = "claude-opus-4-6");

  // Wire up the outbound callback and spawn the worker thread.
  // The outbound_fn posts via CefPostTask in production; in Phase 2 it is a
  // direct stub call (acceptable because handle_browser_action only touches
  // the thread-safe session.inbox).
  //
  // TODO Phase 5: replace the outbound_fn body with:
  //   CefPostTask(TID_UI, base::BindOnce(&SessionManager::on_session_message,
  //                                      base::Unretained(this), session_id,
  //                                      std::move(msg)));
  void start_session(const std::string& session_id);

  // Cancel the worker (if running), persist terminal status, remove from map.
  void destroy_session(const std::string& session_id);

  // Returns nullptr if not found.
  std::shared_ptr<Session> find_session(const std::string& session_id) const;

  // Entry point for all CefPostTask deliveries from worker threads.
  // Must be called on the main thread.
  void on_session_message(const std::string& session_id, OutboundMessage msg);

  // Register / unregister the native browser for a tab so the dispatcher
  // can look it up.  |browser_ptr| is a raw CefBrowser* (stored as void* to
  // keep this header CEF-free).  Must be called on the UI thread.
  // register_tab_browser: called from BrowserTabMac::OnBrowserCreated.
  // unregister_tab_browser: called from BaseClientHandler::OnBeforeClose.
  void register_tab_browser(const std::string& tab_id, void* browser_ptr);
  void unregister_tab_browser(const std::string& tab_id);

  // Initialise BrowserActionDispatcher.  Must be called once after the
  // SessionManager is created and before any sessions start.
  void init_dispatcher();

 private:
  std::unordered_map<std::string, std::shared_ptr<Session>> sessions_;
  TabAllocator tab_allocator_;

  // tab_id → raw CefBrowser*.  Valid only while the browser is open.
  // Entries are removed in unregister_tab_browser (called from OnBeforeClose).
  std::unordered_map<std::string, void*> tab_browsers_;

  // Message handlers — all run on the main thread.
  void handle_display_message(Session& session, DisplayMessage msg);
  void handle_browser_action(Session& session, BrowserActionRequest req);
  void handle_allocate_tab(Session& session, AllocateTabRequest req);
  void handle_status_update(Session& session, SessionStatusUpdate upd);
};
