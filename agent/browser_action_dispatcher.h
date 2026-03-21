#pragma once

#include <functional>
#include <memory>
#include <string>
#include <unordered_map>

#include "agent/messages.h"

// Forward declarations — keeps this header CEF-free so agent/ code can include
// it without pulling in CEF headers.
namespace client { class BaseClientHandler; }

// ---------------------------------------------------------------------------
// BrowserActionDispatcher
//
// Singleton that executes BrowserActionRequests on the main (UI) thread.
//
// Lifecycle
// ---------
//   BrowserActionDispatcher::instance() is available after the first call to
//   BrowserActionDispatcher::create().  It is destroyed when the app exits.
//
// Browser lookup
// --------------
//   The SessionManager registers a BrowserLookupFn at startup.  The dispatcher
//   uses it to obtain a CefRefPtr<CefBrowser> from a string tab_id.
//
// Callbacks into CEF
// ------------------
//   All methods must be called on the CEF UI thread (TID_UI).
//
// JS return values
// ----------------
//   InjectJS wraps the script in a cefQuery call.  The renderer sends back
//   a "agent-js:REQUEST_ID:RESULT_JSON" string.  AgentQueryHandler (registered
//   with BaseClientHandler's message router) picks it up and forwards it here.
//
// Navigation completion
// ---------------------
//   NavigateTo listens for OnLoadingStateChange (isLoading→false) via the
//   static NotifyLoadingStateChange() hook that BaseClientHandler calls.
//   Optional wait_for_selector uses an InjectJS poll loop.
//
// Screenshots
// -----------
//   TakeScreenshot uses CGWindowListCreateImage (macOS only).  The screenshot
//   is written to a temp file; the ToolResult payload is the file path.
// ---------------------------------------------------------------------------

// Opaque forward to avoid including CEF in agent headers.  The .mm file uses
// the full type.
struct CefBrowserOpaque;

class BrowserActionDispatcher {
 public:
  // Returns the browser (as opaque pointer) for a given agent tab_id.
  // Returns nullptr if not found.
  using BrowserLookupFn = std::function<void*(const std::string& tab_id)>;

  // Called when a browser action result is ready.  session_id identifies
  // which session's inbox receives the ToolResult.
  using ResultFn = std::function<void(const std::string& session_id,
                                      ToolResult result)>;

  // ---------------------------------------------------------------------------
  // Singleton management (called from main thread only)
  // ---------------------------------------------------------------------------
  static void create(BrowserLookupFn lookup, ResultFn on_result);
  static BrowserActionDispatcher* instance();
  static void destroy();

  // ---------------------------------------------------------------------------
  // Called by SessionManager on the main thread
  // ---------------------------------------------------------------------------
  void dispatch(const BrowserActionRequest& req);

  // ---------------------------------------------------------------------------
  // Hooks called by BaseClientHandler (main thread)
  // ---------------------------------------------------------------------------

  // Called from BaseClientHandler::OnLoadingStateChange.
  void notify_loading_state_change(int browser_id, bool is_loading);

  // Called from AgentQueryHandler::OnQuery when a "agent-js:…" message arrives.
  void notify_js_result(const std::string& request_id,
                        bool success,
                        const std::string& payload);

 private:
  BrowserActionDispatcher(BrowserLookupFn lookup, ResultFn on_result);
  ~BrowserActionDispatcher();

  // -- helpers -----------------------------------------------------------------
  void* browser_for_tab(const std::string& tab_id) const;

  void do_navigate_to(const BrowserActionRequest& req, const NavigateTo& a);
  void do_inject_js(const BrowserActionRequest& req, const InjectJS& a);
  void do_take_screenshot(const BrowserActionRequest& req, const TakeScreenshot& a);
  void do_read_dom(const BrowserActionRequest& req, const ReadDOM& a);
  void do_simulate_click(const BrowserActionRequest& req, const SimulateClick& a);
  void do_simulate_key(const BrowserActionRequest& req, const SimulateKey& a);
  void do_type_text(const BrowserActionRequest& req, const TypeText& a);
  void do_scroll_page(const BrowserActionRequest& req, const ScrollPage& a);
  void do_get_element_rect(const BrowserActionRequest& req, const GetElementRect& a);
  void do_read_console_log(const BrowserActionRequest& req, const ReadConsoleLog& a);
  void do_open_new_tab(const BrowserActionRequest& req, const OpenNewTab& a);
  void do_close_tab(const BrowserActionRequest& req, const CloseTab& a);
  void do_focus_tab(const BrowserActionRequest& req, const FocusTab& a);
  void do_subscribe_to_event(const BrowserActionRequest& req, const SubscribeToEvent& a);
  void do_unsubscribe_from_event(const BrowserActionRequest& req, const UnsubscribeFromEvent& a);

  void deliver(const std::string& session_id, ToolResult result);
  void error(const std::string& session_id, const std::string& request_id,
             const std::string& msg);

  // -- navigation pending state ------------------------------------------------
  struct PendingNav {
    std::string session_id;
    std::string request_id;
    std::string tab_id;             // needed to re-fetch browser for selector poll
    std::string wait_for_selector;  // "" means no selector wait
    int         selector_timeout_ms;
    int64_t     deadline_ms;        // epoch ms when selector poll times out
  };
  // browser_id → pending navigation
  std::unordered_map<int, PendingNav> pending_navigations_;

  // -- JS eval pending state ---------------------------------------------------
  struct PendingJs {
    std::string session_id;
  };
  // request_id → pending JS eval
  std::unordered_map<std::string, PendingJs> pending_js_;

  // -- fields ------------------------------------------------------------------
  BrowserLookupFn lookup_;
  ResultFn        on_result_;

  static BrowserActionDispatcher* instance_;
};
