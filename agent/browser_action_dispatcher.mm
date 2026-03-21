// macOS-only implementation — links against CEF and AppKit/CoreGraphics.
//
// Build note: add to the cefclient target alongside the other .mm sources.

#include "agent/browser_action_dispatcher.h"

// CEF includes
#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/cef_base.h"
#include "include/cef_task.h"

// macOS system
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <chrono>
#include <cstdio>
#include <string>

// ---------------------------------------------------------------------------
// Module-level singleton
// ---------------------------------------------------------------------------

BrowserActionDispatcher* BrowserActionDispatcher::instance_ = nullptr;

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

BrowserActionDispatcher::BrowserActionDispatcher(BrowserLookupFn lookup,
                                                 ResultFn on_result)
    : lookup_(std::move(lookup)), on_result_(std::move(on_result)) {}

BrowserActionDispatcher::~BrowserActionDispatcher() = default;

// static
void BrowserActionDispatcher::create(BrowserLookupFn lookup,
                                     ResultFn on_result) {
  if (!instance_)
    instance_ = new BrowserActionDispatcher(std::move(lookup),
                                            std::move(on_result));
}

// static
BrowserActionDispatcher* BrowserActionDispatcher::instance() {
  return instance_;
}

// static
void BrowserActionDispatcher::destroy() {
  delete instance_;
  instance_ = nullptr;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static int64_t now_ms() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(steady_clock::now().time_since_epoch())
      .count();
}

// Cast the opaque pointer back to a CefBrowser ref.
static inline CefRefPtr<CefBrowser> as_browser(void* p) {
  return reinterpret_cast<CefBrowser*>(p);
}

void* BrowserActionDispatcher::browser_for_tab(const std::string& tab_id) const {
  return lookup_ ? lookup_(tab_id) : nullptr;
}

void BrowserActionDispatcher::deliver(const std::string& session_id,
                                      ToolResult result) {
  if (on_result_) on_result_(session_id, std::move(result));
}

void BrowserActionDispatcher::error(const std::string& session_id,
                                    const std::string& request_id,
                                    const std::string& msg) {
  ToolResult r;
  r.request_id = request_id;
  r.success    = false;
  r.payload    = msg;
  deliver(session_id, std::move(r));
}

// ---------------------------------------------------------------------------
// dispatch() — main entry point
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::dispatch(const BrowserActionRequest& req) {
  std::visit([&](const auto& action) {
    using T = std::decay_t<decltype(action)>;
    if constexpr (std::is_same_v<T, NavigateTo>)
      do_navigate_to(req, action);
    else if constexpr (std::is_same_v<T, InjectJS>)
      do_inject_js(req, action);
    else if constexpr (std::is_same_v<T, TakeScreenshot>)
      do_take_screenshot(req, action);
    else if constexpr (std::is_same_v<T, ReadDOM>)
      do_read_dom(req, action);
    else if constexpr (std::is_same_v<T, SimulateClick>)
      do_simulate_click(req, action);
    else if constexpr (std::is_same_v<T, SimulateKey>)
      do_simulate_key(req, action);
    else if constexpr (std::is_same_v<T, TypeText>)
      do_type_text(req, action);
    else if constexpr (std::is_same_v<T, ScrollPage>)
      do_scroll_page(req, action);
    else if constexpr (std::is_same_v<T, GetElementRect>)
      do_get_element_rect(req, action);
    else if constexpr (std::is_same_v<T, ReadConsoleLog>)
      do_read_console_log(req, action);
    else if constexpr (std::is_same_v<T, OpenNewTab>)
      do_open_new_tab(req, action);
    else if constexpr (std::is_same_v<T, CloseTab>)
      do_close_tab(req, action);
    else if constexpr (std::is_same_v<T, FocusTab>)
      do_focus_tab(req, action);
    else if constexpr (std::is_same_v<T, SubscribeToEvent>)
      do_subscribe_to_event(req, action);
    else if constexpr (std::is_same_v<T, UnsubscribeFromEvent>)
      do_unsubscribe_from_event(req, action);
  }, req.action);
}

// ---------------------------------------------------------------------------
// NavigateTo
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_navigate_to(const BrowserActionRequest& req,
                                              const NavigateTo& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  int browser_id = browser->GetIdentifier();

  PendingNav nav;
  nav.session_id          = req.session_id;
  nav.request_id          = req.request_id;
  nav.tab_id              = a.tab_id;
  nav.wait_for_selector   = a.wait_for_selector;
  nav.selector_timeout_ms = a.selector_timeout_ms;
  nav.deadline_ms         = now_ms() + a.selector_timeout_ms;
  pending_navigations_[browser_id] = std::move(nav);

  browser->GetMainFrame()->LoadURL(a.url);
}

void BrowserActionDispatcher::notify_loading_state_change(int browser_id,
                                                           bool is_loading) {
  if (is_loading) return;  // we care about load-complete only

  auto it = pending_navigations_.find(browser_id);
  if (it == pending_navigations_.end()) return;

  PendingNav nav = std::move(it->second);
  pending_navigations_.erase(it);

  if (nav.wait_for_selector.empty()) {
    // No selector wait — done.
    ToolResult r;
    r.request_id = nav.request_id;
    r.success    = true;
    r.payload    = "{\"loaded\":true}";
    deliver(nav.session_id, std::move(r));
    return;
  }

  // Inject a poll loop that waits for the selector.
  // We re-use do_inject_js by building a synthetic request.
  std::string escaped = nav.wait_for_selector;
  // Very basic escaping — replace single quotes.
  for (size_t i = 0; i < escaped.size(); ++i) {
    if (escaped[i] == '\'') { escaped.replace(i, 1, "\\'"); i++; }
  }

  // We store the nav back as pending so the JS result continues to wait_for_selector
  // through notify_js_result — but here we simply do a one-shot check after
  // a 200 ms delay via a RecordedTimer-style approach. For simplicity we use
  // a single InjectJS that polls with queueMicrotask / setTimeout and resolves
  // via cefQuery.  The cefQuery result comes back through notify_js_result.

  std::string script =
      "(function(){"
      "  var deadline = Date.now() + " + std::to_string(nav.selector_timeout_ms) + ";"
      "  function poll() {"
      "    var el = document.querySelector('" + escaped + "');"
      "    if (el) { return '{\"found\":true}'; }"
      "    if (Date.now() >= deadline) { return '{\"found\":false,\"timeout\":true}'; }"
      "    return null;"
      "  }"
      "  (function tick() {"
      "    var r = poll();"
      "    if (r !== null) {"
      "      window.cefQuery({request: 'agent-js:' + '" + nav.request_id + "' + ':' + r,"
      "        onSuccess: function(){}, onFailure: function(){}});"
      "    } else {"
      "      setTimeout(tick, 100);"
      "    }"
      "  })();"
      "  return 'polling';"
      "})()";

  // Register the pending JS entry so notify_js_result can deliver.
  pending_js_[nav.request_id] = PendingJs{nav.session_id};

  // Look up the browser again (by browser_id this time we need the CefBrowser).
  // We don't have a reverse map from browser_id → CefBrowser here.
  // Instead we rely on the original raw pointer still being valid — this is
  // safe because we're on the UI thread and the browser hasn't been destroyed
  // (we just received a load event from it).
  //
  // Re-fetch via lookup using the tab_id stored in the original request.  But
  // we no longer have the tab_id here.  Work around: the script is injected
  // via the frame; we just obtained the browser above — stash a raw pointer
  // approach is unsafe.  Instead, use a WeakRef trick: nothing is safe here
  // except re-doing the lookup.  Since we can't recover the tab_id, store it.
  //
  // Redesign note: PendingNav should store the tab_id for this re-lookup.
  // For now, stash tab_id in PendingNav (added below; won't affect header since
  // PendingNav is a private struct defined in the .mm file's spirit via the .h).
  //
  // TODO: add tab_id to PendingNav.  For this first pass, execute the JS
  // directly since we still hold the browser ref on the stack.
  //
  // Inject the selector poll script using the tab_id stored in PendingNav.
  void* raw2 = lookup_(nav.tab_id);
  if (raw2) {
    CefRefPtr<CefBrowser> b2 = as_browser(raw2);
    b2->GetMainFrame()->ExecuteJavaScript(script, b2->GetMainFrame()->GetURL(), 0);
  } else {
    // Browser went away; deliver timeout.
    ToolResult r;
    r.request_id = nav.request_id;
    r.success    = false;
    r.payload    = "{\"error\":\"browser gone\"}";
    deliver(nav.session_id, std::move(r));
    pending_js_.erase(nav.request_id);
  }
}

// ---------------------------------------------------------------------------
// InjectJS
// ---------------------------------------------------------------------------

// Escape a JS string for embedding in a JS string literal (single-quoted).
static std::string escape_js_string(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (unsigned char c : s) {
    switch (c) {
      case '\'': out += "\\'";  break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      default:   out += (char)c;
    }
  }
  return out;
}

void BrowserActionDispatcher::do_inject_js(const BrowserActionRequest& req,
                                            const InjectJS& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  pending_js_[req.request_id] = PendingJs{req.session_id};

  // Wrap the caller's script so the return value comes back via cefQuery.
  // The result is JSON-stringified; errors are caught.
  std::string wrapper =
      "(function(){"
      "  var __result__;"
      "  try { __result__ = JSON.stringify((function(){ " + a.script + " })()); }"
      "  catch(e) { __result__ = JSON.stringify({error: e.message}); }"
      "  if (__result__ === undefined) __result__ = 'null';"
      "  window.cefQuery({"
      "    request: 'agent-js:' + '" + escape_js_string(req.request_id) + "' + ':' + __result__,"
      "    onSuccess: function(){}, onFailure: function(c,m){}"
      "  });"
      "})();";

  browser->GetMainFrame()->ExecuteJavaScript(
      wrapper, browser->GetMainFrame()->GetURL(), 0);
}

void BrowserActionDispatcher::notify_js_result(const std::string& request_id,
                                                bool success,
                                                const std::string& payload) {
  auto it = pending_js_.find(request_id);
  if (it == pending_js_.end()) return;

  std::string session_id = it->second.session_id;
  pending_js_.erase(it);

  ToolResult r;
  r.request_id = request_id;
  r.success    = success;
  r.payload    = payload;
  deliver(session_id, std::move(r));
}

// ---------------------------------------------------------------------------
// TakeScreenshot  (macOS: CGWindowListCreateImage)
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_take_screenshot(
    const BrowserActionRequest& req, const TakeScreenshot& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  // GetWindowHandle returns NSView* on macOS.
  CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
  NSView* view = (__bridge NSView*)handle;
  NSWindow* window = [view window];
  if (!window) {
    error(req.session_id, req.request_id, "browser window not found");
    return;
  }

  CGWindowID windowID = (CGWindowID)[window windowNumber];
  CGImageRef image = CGWindowListCreateImage(
      CGRectNull,
      kCGWindowListOptionIncludingWindow,
      windowID,
      kCGWindowImageBoundsIgnoreFraming);

  if (!image) {
    error(req.session_id, req.request_id, "CGWindowListCreateImage failed");
    return;
  }

  // Write to a temp PNG file.
  NSString* tmpDir  = NSTemporaryDirectory();
  NSString* fname   = [NSString stringWithFormat:@"openclam_screenshot_%@.png",
                       [[NSUUID UUID] UUIDString]];
  NSString* tmpPath = [tmpDir stringByAppendingPathComponent:fname];

  CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:tmpPath];
  CGImageDestinationRef dest =
      CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
  if (!dest) {
    CGImageRelease(image);
    error(req.session_id, req.request_id, "CGImageDestinationCreateWithURL failed");
    return;
  }
  CGImageDestinationAddImage(dest, image, nullptr);
  bool written = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(image);

  if (!written) {
    error(req.session_id, req.request_id, "CGImageDestinationFinalize failed");
    return;
  }

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = std::string("{\"path\":\"") + [tmpPath UTF8String] + "\"}";
  deliver(req.session_id, std::move(r));
}

// ---------------------------------------------------------------------------
// ReadDOM — InjectJS with a querySelector extraction script
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_read_dom(const BrowserActionRequest& req,
                                           const ReadDOM& a) {
  InjectJS ijs;
  ijs.tab_id = a.tab_id;
  ijs.script =
      "var __el__ = document.querySelector('" + escape_js_string(a.selector) + "');"
      "if (!__el__) return JSON.stringify({error:'not found'});"
      "return JSON.stringify({outerHTML: __el__.outerHTML,"
      "                       innerText: __el__.innerText});";
  do_inject_js(req, ijs);
}

// ---------------------------------------------------------------------------
// GetElementRect — InjectJS with getBoundingClientRect
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_get_element_rect(
    const BrowserActionRequest& req, const GetElementRect& a) {
  InjectJS ijs;
  ijs.tab_id = a.tab_id;
  ijs.script =
      "var __el__ = document.querySelector('" + escape_js_string(a.selector) + "');"
      "if (!__el__) return JSON.stringify({error:'not found'});"
      "var r = __el__.getBoundingClientRect();"
      "return JSON.stringify({x:r.x,y:r.y,width:r.width,height:r.height,"
      "                       top:r.top,left:r.left,bottom:r.bottom,right:r.right});";
  do_inject_js(req, ijs);
}

// ---------------------------------------------------------------------------
// ReadConsoleLog — returns accumulated logs injected by a prior subscription
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_read_console_log(
    const BrowserActionRequest& req, const ReadConsoleLog& a) {
  InjectJS ijs;
  ijs.tab_id = a.tab_id;
  ijs.script =
      "return JSON.stringify(window.__openclam_console_log__ || []);";
  do_inject_js(req, ijs);
}

// ---------------------------------------------------------------------------
// Input simulation helpers
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_simulate_click(
    const BrowserActionRequest& req, const SimulateClick& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  CefMouseEvent mouse;
  mouse.x = a.x;
  mouse.y = a.y;
  mouse.modifiers = 0;

  cef_mouse_button_type_t btn = MBT_LEFT;
  if (a.button == 1) btn = MBT_RIGHT;
  else if (a.button == 2) btn = MBT_MIDDLE;

  browser->GetHost()->SendMouseClickEvent(mouse, btn, false, 1);  // down
  browser->GetHost()->SendMouseClickEvent(mouse, btn, true,  1);  // up

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"clicked\":true}";
  deliver(req.session_id, std::move(r));
}

void BrowserActionDispatcher::do_simulate_key(
    const BrowserActionRequest& req, const SimulateKey& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  // Map a small set of named keys; fall back to the first character.
  CefKeyEvent key_event;
  key_event.modifiers = 0;
  key_event.type = KEYEVENT_RAWKEYDOWN;

  // Parse modifiers string ("ctrl", "shift", "alt", "meta", comma-separated).
  if (a.modifiers.find("ctrl")  != std::string::npos) key_event.modifiers |= EVENTFLAG_CONTROL_DOWN;
  if (a.modifiers.find("shift") != std::string::npos) key_event.modifiers |= EVENTFLAG_SHIFT_DOWN;
  if (a.modifiers.find("alt")   != std::string::npos) key_event.modifiers |= EVENTFLAG_ALT_DOWN;
  if (a.modifiers.find("meta")  != std::string::npos) key_event.modifiers |= EVENTFLAG_COMMAND_DOWN;

  // Special key mapping
  if      (a.key == "Enter")     { key_event.windows_key_code = 0x0D; }
  else if (a.key == "Tab")       { key_event.windows_key_code = 0x09; }
  else if (a.key == "Escape")    { key_event.windows_key_code = 0x1B; }
  else if (a.key == "Backspace") { key_event.windows_key_code = 0x08; }
  else if (a.key == "Delete")    { key_event.windows_key_code = 0x2E; }
  else if (a.key == "ArrowLeft") { key_event.windows_key_code = 0x25; }
  else if (a.key == "ArrowRight"){ key_event.windows_key_code = 0x27; }
  else if (a.key == "ArrowUp")   { key_event.windows_key_code = 0x26; }
  else if (a.key == "ArrowDown") { key_event.windows_key_code = 0x28; }
  else if (!a.key.empty())       { key_event.windows_key_code = (int)(unsigned char)a.key[0]; }

  browser->GetHost()->SendKeyEvent(key_event);
  key_event.type = KEYEVENT_KEYUP;
  browser->GetHost()->SendKeyEvent(key_event);

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"sent\":true}";
  deliver(req.session_id, std::move(r));
}

void BrowserActionDispatcher::do_type_text(
    const BrowserActionRequest& req, const TypeText& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  for (unsigned char c : a.text) {
    CefKeyEvent key;
    key.type             = KEYEVENT_CHAR;
    key.modifiers        = 0;
    key.windows_key_code = c;
    key.character        = c;
    browser->GetHost()->SendKeyEvent(key);
  }

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"typed\":true}";
  deliver(req.session_id, std::move(r));
}

void BrowserActionDispatcher::do_scroll_page(
    const BrowserActionRequest& req, const ScrollPage& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  CefMouseEvent mouse;
  mouse.x = 0; mouse.y = 0; mouse.modifiers = 0;
  browser->GetHost()->SendMouseWheelEvent(mouse, a.delta_x, a.delta_y);

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"scrolled\":true}";
  deliver(req.session_id, std::move(r));
}

// ---------------------------------------------------------------------------
// Tab management
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_open_new_tab(
    const BrowserActionRequest& req, const OpenNewTab& /*a*/) {
  // Tab creation must go through the main thread's TabAllocator in
  // SessionManager (it creates a BrowserTabMac).  We deliver an error here;
  // the agent loop's built-in OpenNewTab path uses AllocateTabRequest instead.
  error(req.session_id, req.request_id,
        "OpenNewTab must be handled by SessionManager via AllocateTabRequest");
}

void BrowserActionDispatcher::do_close_tab(
    const BrowserActionRequest& req, const CloseTab& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);
  browser->GetHost()->CloseBrowser(false);

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"closed\":true}";
  deliver(req.session_id, std::move(r));
}

void BrowserActionDispatcher::do_focus_tab(
    const BrowserActionRequest& req, const FocusTab& a) {
  void* raw = browser_for_tab(a.tab_id);
  if (!raw) { error(req.session_id, req.request_id, "tab not found"); return; }
  CefRefPtr<CefBrowser> browser = as_browser(raw);

  CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
  NSView* view = (__bridge NSView*)handle;
  [[view window] makeKeyAndOrderFront:nil];
  [view setNeedsDisplay:YES];

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"focused\":true}";
  deliver(req.session_id, std::move(r));
}

// ---------------------------------------------------------------------------
// Event subscriptions (stub — full implementation requires JS injection
// to instrument mutation observers / network interception)
// ---------------------------------------------------------------------------

void BrowserActionDispatcher::do_subscribe_to_event(
    const BrowserActionRequest& req, const SubscribeToEvent& a) {
  // For now return a subscription_id so the agent can unsubscribe.
  // A full implementation would inject a MutationObserver / fetch interceptor
  // into the page and route events back to the UI thread via cefQuery.
  static std::atomic<int> sub_counter{0};
  std::string sub_id = "sub_" + a.tab_id + "_" +
                       std::to_string(sub_counter.fetch_add(1));

  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"subscription_id\":\"" + sub_id + "\"}";
  deliver(req.session_id, std::move(r));
}

void BrowserActionDispatcher::do_unsubscribe_from_event(
    const BrowserActionRequest& req, const UnsubscribeFromEvent& /*a*/) {
  ToolResult r;
  r.request_id = req.request_id;
  r.success    = true;
  r.payload    = "{\"unsubscribed\":true}";
  deliver(req.session_id, std::move(r));
}
