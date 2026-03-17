// Copyright (c) 2015 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "tests/cefclient/browser/root_window_mac.h"

#include <Cocoa/Cocoa.h>

#include <algorithm>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/views/cef_display.h"
#include "tests/cefclient/browser/browser_window_osr_mac.h"
#include "tests/cefclient/browser/browser_window_std_mac.h"
#include "tests/cefclient/browser/client_prefs.h"
#include "tests/cefclient/browser/main_context.h"
#include "tests/cefclient/browser/osr_renderer_settings.h"
#include "tests/cefclient/browser/root_window_manager.h"
#include "tests/cefclient/browser/temp_window.h"
#include "tests/cefclient/browser/util_mac.h"
#include "tests/cefclient/browser/window_test_runner_mac.h"
#include "tests/shared/browser/main_message_loop.h"
#include "tests/shared/common/client_switches.h"

@interface RootWindowDelegate : NSObject <NSWindowDelegate> {
 @private
  NSWindow* window_;
  client::RootWindowMac* root_window_;
  std::optional<CefRect> last_visible_bounds_;
  bool force_close_;
}

@property(nonatomic, readonly) client::RootWindowMac* root_window;
@property(nonatomic, readwrite) std::optional<CefRect> last_visible_bounds;
@property(nonatomic, readwrite) bool force_close;

- (id)initWithWindow:(NSWindow*)window
       andRootWindow:(client::RootWindowMac*)root_window;
- (IBAction)goBack:(id)sender;
- (IBAction)goForward:(id)sender;
- (IBAction)reload:(id)sender;
- (IBAction)stopLoading:(id)sender;
- (IBAction)takeURLStringValueFrom:(NSTextField*)sender;
- (IBAction)tabButtonClicked:(id)sender;
- (IBAction)tabCloseButtonClicked:(id)sender;
- (IBAction)newTabButtonClicked:(id)sender;
@end

namespace client {

namespace {

#define BUTTON_HEIGHT 22
#define BUTTON_WIDTH 72
#define BUTTON_MARGIN 8
#define URLBAR_HEIGHT 32
#define TABBAR_HEIGHT 36
#define TAB_MAX_WIDTH 200
#define TAB_MIN_WIDTH 80
#define TAB_CLOSE_SIZE 16
#define TAB_PADDING 6

NSButton* MakeButton(NSRect* rect, NSString* title, NSView* parent) {
  NSButton* button = [[NSButton alloc] initWithFrame:*rect];
#if !__has_feature(objc_arc)
  [button autorelease];
#endif
  [button setTitle:title];
  [button setBezelStyle:NSBezelStyleSmallSquare];
  [button setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin)];
  [parent addSubview:button];
  rect->origin.x += BUTTON_WIDTH;
  return button;
}

NSRect ClampNSBoundsToWorkArea(const NSRect& frame_bounds,
                               const CefRect& display_bounds,
                               const CefRect& work_area) {
  NSRect bounds = frame_bounds;
  const int work_area_y =
      display_bounds.height - work_area.height - work_area.y;
  if (bounds.size.width > work_area.width) bounds.size.width = work_area.width;
  if (bounds.size.height > work_area.height)
    bounds.size.height = work_area.height;
  if (bounds.origin.x < work_area.x)
    bounds.origin.x = work_area.x;
  else if (bounds.origin.x + bounds.size.width >= work_area.x + work_area.width)
    bounds.origin.x = work_area.x + work_area.width - bounds.size.width;
  if (bounds.origin.y < work_area_y)
    bounds.origin.y = work_area_y;
  else if (bounds.origin.y + bounds.size.height >=
           work_area_y + work_area.height)
    bounds.origin.y = work_area_y + work_area.height - bounds.size.height;
  return bounds;
}

void GetNSBoundsInDisplay(const CefRect& dip_bounds,
                          bool input_content_bounds,
                          NSWindowStyleMask style_mask,
                          bool add_controls,
                          NSRect& frame_rect,
                          NSRect& content_rect) {
  auto display =
      CefDisplay::GetDisplayMatchingBounds(dip_bounds, false);
  const auto display_bounds = display->GetBounds();
  const auto display_work_area = display->GetWorkArea();

  NSRect requested_rect = NSMakeRect(dip_bounds.x, dip_bounds.y,
                                     dip_bounds.width, dip_bounds.height);
  requested_rect.origin.y = display_bounds.height - requested_rect.size.height -
                             requested_rect.origin.y;

  // Controls height = URL bar + tab bar.
  const CGFloat controls_h = add_controls ? (URLBAR_HEIGHT + TABBAR_HEIGHT) : 0;
  bool changed_content_bounds = false;

  if (input_content_bounds) {
    content_rect = requested_rect;
    frame_rect =
        [NSWindow frameRectForContentRect:content_rect styleMask:style_mask];
    frame_rect.size.height += controls_h;
    frame_rect.origin = requested_rect.origin;
  } else {
    frame_rect = requested_rect;
    content_rect =
        [NSWindow contentRectForFrameRect:frame_rect styleMask:style_mask];
    changed_content_bounds = true;
  }

  const NSRect new_frame_rect =
      ClampNSBoundsToWorkArea(frame_rect, display_bounds, display_work_area);
  if (!NSEqualRects(frame_rect, new_frame_rect)) {
    frame_rect = new_frame_rect;
    content_rect =
        [NSWindow contentRectForFrameRect:frame_rect styleMask:style_mask];
    changed_content_bounds = true;
  }

  if (changed_content_bounds && add_controls) {
    content_rect.origin.y -= controls_h;
    content_rect.size.height -= controls_h;
  }
}

}  // namespace

// ===========================================================================
// BrowserTabMac
//
// One tab = one BrowserWindowStdMac + per-tab state (title, url, etc.).
// Implements BrowserWindow::Delegate so it receives CEF callbacks directly
// and stores state on itself.  Reports to its parent (RootWindowMacImpl) via
// three simple callbacks: OnTabReady / OnTabUpdated / OnTabDestroyed.
// ===========================================================================

class RootWindowMacImpl;

class BrowserTabMac : public BrowserWindow::Delegate {
 public:
  BrowserTabMac(int tab_id,
                RootWindowMacImpl* parent,
                bool with_controls,
                const std::string& url)
      : tab_id_(tab_id), parent_(parent) {
    browser_window_ =
        std::make_unique<BrowserWindowStdMac>(this, with_controls, url);
    title_ = url.empty() ? "New Tab" : url;
    url_ = url;
  }

  // Not copyable.
  BrowserTabMac(const BrowserTabMac&) = delete;
  BrowserTabMac& operator=(const BrowserTabMac&) = delete;

  // Accessors.
  int tab_id() const { return tab_id_; }
  BrowserWindowStdMac* browser_window() { return browser_window_.get(); }
  const std::string& title() const { return title_; }
  const std::string& url() const { return url_; }
  bool is_loading() const { return is_loading_; }
  bool can_go_back() const { return can_go_back_; }
  bool can_go_forward() const { return can_go_forward_; }
  bool is_ready() const { return ready_; }  // browser has been created

  // BrowserWindow::Delegate ------------------------------------------------
  bool UseAlloyStyle() const override;

  void OnBrowserCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBrowserWindowClosing() override {}
  void OnBrowserWindowDestroyed() override;

  void OnSetAddress(const std::string& url) override {
    url_ = url;
    NotifyParent();
  }

  void OnSetTitle(const std::string& title) override {
    title_ = title.empty() ? "New Tab" : title;
    NotifyParent();
  }

  void OnSetFullscreen(bool /*fullscreen*/) override {}
  void OnAutoResize(const CefSize& /*new_size*/) override {}
  void OnContentsBounds(const CefRect& /*new_bounds*/) override {}

  void OnSetLoadingState(bool isLoading,
                         bool canGoBack,
                         bool canGoForward) override {
    is_loading_ = isLoading;
    can_go_back_ = canGoBack;
    can_go_forward_ = canGoForward;
    NotifyParent();
  }

  void OnSetDraggableRegions(
      const std::vector<CefDraggableRegion>&) override {}

 private:
  void NotifyParent();  // defined after RootWindowMacImpl

  int tab_id_;
  RootWindowMacImpl* parent_;  // not owned
  std::unique_ptr<BrowserWindowStdMac> browser_window_;
  std::string title_ = "New Tab";
  std::string url_;
  bool ready_ = false;
  bool is_loading_ = false;
  bool can_go_back_ = false;
  bool can_go_forward_ = false;
};

// ===========================================================================
// RootWindowMacImpl
// ===========================================================================

class RootWindowMacImpl
    : public base::RefCountedThreadSafe<RootWindowMacImpl, DeleteOnMainThread> {
 public:
  explicit RootWindowMacImpl(RootWindowMac& root_window);
  ~RootWindowMacImpl();

  void OnNativeWindowClosed();
  void CreateFirstTab(const std::string& url);
  void CreateRootWindow(const CefBrowserSettings& settings,
                        bool initially_hidden);

  // RootWindow interface.
  void Init(RootWindow::Delegate* delegate,
            std::unique_ptr<RootWindowConfig> config,
            const CefBrowserSettings& settings);
  void InitAsPopup(RootWindow::Delegate* delegate,
                   bool with_controls,
                   bool with_osr,
                   const CefPopupFeatures& popupFeatures,
                   CefWindowInfo& windowInfo,
                   CefRefPtr<CefClient>& client,
                   CefBrowserSettings& settings);
  void Show(RootWindow::ShowMode mode);
  void Hide();
  void SetBounds(int x, int y, size_t width, size_t height,
                 bool content_bounds);
  bool DefaultToContentBounds() const;
  void Close(bool force);
  void SetDeviceScaleFactor(float device_scale_factor);
  std::optional<float> GetDeviceScaleFactor() const;
  CefRefPtr<CefBrowser> GetBrowser() const;
  ClientWindowHandle GetWindowHandle() const;
  bool WithWindowlessRendering() const;

  // Tab management (called by RootWindowMac public methods or RootWindowDelegate).
  void OpenNewTab(const std::string& url);
  void SwitchToTab(int idx);
  void CloseTab(int idx, bool force);
  bool RequestCloseAllBrowsers(bool force);

  // Callbacks from BrowserTabMac.
  void OnTabReady(BrowserTabMac* tab);    // browser created
  void OnTabUpdated(BrowserTabMac* tab);  // title/url/loading changed
  void OnTabDestroyed(BrowserTabMac* tab);

  // Legacy BrowserWindow::Delegate path (OSR popup).
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser);
  void OnBrowserWindowDestroyed();
  void OnSetAddress(const std::string& url);
  void OnSetTitle(const std::string& title);
  void OnSetFullscreen(bool fullscreen);
  void OnAutoResize(const CefSize& new_size);
  void OnSetLoadingState(bool isLoading, bool canGoBack, bool canGoForward);
  void OnSetDraggableRegions(const std::vector<CefDraggableRegion>& regions);

  void NotifyDestroyedIfDone();

  // Tab bar helpers.
  void CreateTabBar(NSView* contentView);
  void RebuildTabBar();

  BrowserWindowStdMac* ActiveBrowserWindowStd() const;
  BrowserWindow* ActiveBrowserWindow() const;

  // ---- Data ----

  RootWindowMac& root_window_;
  bool with_controls_ = false;
  bool with_osr_ = false;
  OsrRendererSettings osr_settings_;
  bool is_popup_ = false;
  CefRect initial_bounds_;
  cef_show_state_t initial_show_state_ = CEF_SHOW_STATE_NORMAL;

  // For OSR / popup path (single-browser, pre-tab).
  std::unique_ptr<BrowserWindow> browser_window_;

  // Tabs (standard, non-OSR).
  std::vector<std::unique_ptr<BrowserTabMac>> tabs_;
  // Tabs being torn down asynchronously; kept alive until browser is gone.
  std::vector<std::unique_ptr<BrowserTabMac>> closing_tabs_;
  int active_tab_idx_ = 0;
  int next_tab_id_ = 0;

  // Cached for creating new tabs after window is open.
  CefBrowserSettings cached_settings_;
  CefRefPtr<CefRequestContext> cached_request_context_;

  NSWindow* window_ = nil;
  RootWindowDelegate* window_delegate_ = nil;
  NSView* tab_bar_view_ = nil;

  NSButton* back_button_ = nil;
  NSButton* forward_button_ = nil;
  NSButton* reload_button_ = nil;
  NSButton* stop_button_ = nil;
  NSTextField* url_textfield_ = nil;

  bool window_destroyed_ = false;
  bool browser_destroyed_ = false;  // used for OSR/popup path only
};

// ---------------------------------------------------------------------------
// BrowserTabMac method bodies (need RootWindowMacImpl defined first)
// ---------------------------------------------------------------------------

bool BrowserTabMac::UseAlloyStyle() const {
  return parent_->root_window_.IsAlloyStyle();
}

void BrowserTabMac::OnBrowserCreated(CefRefPtr<CefBrowser> /*browser*/) {
  ready_ = true;
  parent_->OnTabReady(this);
}

void BrowserTabMac::OnBrowserWindowDestroyed() {
  parent_->OnTabDestroyed(this);
}

void BrowserTabMac::NotifyParent() {
  parent_->OnTabUpdated(this);
}

// ---------------------------------------------------------------------------
// RootWindowMacImpl
// ---------------------------------------------------------------------------

RootWindowMacImpl::RootWindowMacImpl(RootWindowMac& root_window)
    : root_window_(root_window) {}

RootWindowMacImpl::~RootWindowMacImpl() {
  REQUIRE_MAIN_THREAD();
  DCHECK(window_destroyed_);
}

// ---- Init ------------------------------------------------------------------

void RootWindowMacImpl::Init(RootWindow::Delegate* delegate,
                              std::unique_ptr<RootWindowConfig> config,
                              const CefBrowserSettings& settings) {
  DCHECK(!root_window_.initialized_);

  with_controls_ = config->with_controls;
  with_osr_ = config->with_osr;
  cached_settings_ = settings;

  if (!config->bounds.IsEmpty()) {
    initial_bounds_ = config->bounds;
    initial_show_state_ = config->show_state;
  } else {
    std::optional<CefRect> bounds;
    if (prefs::LoadWindowRestorePreferences(initial_show_state_, bounds) &&
        bounds) {
      initial_bounds_ = *bounds;
    }
  }

  if (with_osr_) {
    // OSR path: use original single-browser approach.
    MainContext::Get()->PopulateOsrSettings(&osr_settings_);
    browser_window_.reset(new BrowserWindowOsrMac(
        &root_window_, with_controls_, config->url, osr_settings_));
  } else {
    CreateFirstTab(config->url);
  }

  root_window_.initialized_ = true;
  CreateRootWindow(settings, config->initially_hidden);
}

void RootWindowMacImpl::InitAsPopup(RootWindow::Delegate* delegate,
                                     bool with_controls,
                                     bool with_osr,
                                     const CefPopupFeatures& popupFeatures,
                                     CefWindowInfo& windowInfo,
                                     CefRefPtr<CefClient>& client,
                                     CefBrowserSettings& settings) {
  DCHECK(delegate);
  DCHECK(!root_window_.initialized_);

  with_controls_ = with_controls;
  with_osr_ = with_osr;
  is_popup_ = true;
  cached_settings_ = settings;

  if (popupFeatures.xSet) initial_bounds_.x = popupFeatures.x;
  if (popupFeatures.ySet) initial_bounds_.y = popupFeatures.y;
  if (popupFeatures.widthSet) initial_bounds_.width = popupFeatures.width;
  if (popupFeatures.heightSet) initial_bounds_.height = popupFeatures.height;

  // Popups use the original single-browser path.
  browser_window_.reset(
      new BrowserWindowStdMac(&root_window_, with_controls, std::string()));
  root_window_.initialized_ = true;

  browser_window_->GetPopupConfig(TempWindow::GetWindowHandle(), windowInfo,
                                  client, settings);
}

void RootWindowMacImpl::CreateFirstTab(const std::string& url) {
  auto tab = std::make_unique<BrowserTabMac>(next_tab_id_++, this,
                                              with_controls_, url);
  tabs_.push_back(std::move(tab));
  active_tab_idx_ = 0;
}

// ---- Show / Hide / Close ---------------------------------------------------

void RootWindowMacImpl::Show(RootWindow::ShowMode mode) {
  REQUIRE_MAIN_THREAD();
  if (!window_) return;

  const bool is_visible = [window_ isVisible];
  const bool is_minimized = [window_ isMiniaturized];
  const bool is_maximized = [window_ isZoomed];

  if ((mode == RootWindow::ShowMinimized && is_minimized) ||
      (mode == RootWindow::ShowMaximized && is_maximized) ||
      (mode == RootWindow::ShowNormal && is_visible))
    return;

  if (is_minimized) [window_ deminiaturize:nil];
  else if (is_maximized) [window_ performZoom:nil];

  if (![window_ isVisible]) [window_ makeKeyAndOrderFront:nil];

  if (mode == RootWindow::ShowMinimized) [window_ performMiniaturize:nil];
  else if (mode == RootWindow::ShowMaximized) [window_ performZoom:nil];
}

void RootWindowMacImpl::Hide() {
  REQUIRE_MAIN_THREAD();
  if (!window_) return;
  if ([window_ isMiniaturized]) [window_ deminiaturize:nil];
  [window_ orderOut:nil];
}

void RootWindowMacImpl::SetBounds(int x, int y, size_t width, size_t height,
                                   bool content_bounds) {
  REQUIRE_MAIN_THREAD();
  if (!window_) return;

  const CefRect dip_bounds(x, y, static_cast<int>(width),
                            static_cast<int>(height));
  const bool add_controls = WithWindowlessRendering() || with_controls_;
  NSRect frame_rect, content_rect;
  GetNSBoundsInDisplay(dip_bounds, content_bounds, [window_ styleMask],
                       add_controls, frame_rect, content_rect);
  [window_ setFrame:frame_rect display:YES];
}

bool RootWindowMacImpl::DefaultToContentBounds() const {
  if (!WithWindowlessRendering()) return false;
  if (osr_settings_.real_screen_bounds) return false;
  return true;
}

void RootWindowMacImpl::Close(bool force) {
  REQUIRE_MAIN_THREAD();
  if (window_) {
    static_cast<RootWindowDelegate*>([window_ delegate]).force_close = force;
    [window_ performClose:nil];
    window_destroyed_ = true;
  }
}

void RootWindowMacImpl::SetDeviceScaleFactor(float device_scale_factor) {
  REQUIRE_MAIN_THREAD();
  if (browser_window_ && with_osr_)
    browser_window_->SetDeviceScaleFactor(device_scale_factor);
}

std::optional<float> RootWindowMacImpl::GetDeviceScaleFactor() const {
  REQUIRE_MAIN_THREAD();
  if (browser_window_ && with_osr_)
    return browser_window_->GetDeviceScaleFactor();
  return std::nullopt;
}

CefRefPtr<CefBrowser> RootWindowMacImpl::GetBrowser() const {
  REQUIRE_MAIN_THREAD();
  if (browser_window_) return browser_window_->GetBrowser();  // OSR path
  if (!tabs_.empty())
    return tabs_[active_tab_idx_]->browser_window()->GetBrowser();
  return nullptr;
}

ClientWindowHandle RootWindowMacImpl::GetWindowHandle() const {
  REQUIRE_MAIN_THREAD();
  return CAST_NSVIEW_TO_CEF_WINDOW_HANDLE([window_ contentView]);
}

bool RootWindowMacImpl::WithWindowlessRendering() const {
  REQUIRE_MAIN_THREAD();
  DCHECK(root_window_.initialized_);
  return with_osr_;
}

void RootWindowMacImpl::OnNativeWindowClosed() {
  window_ = nil;
  window_destroyed_ = true;
  NotifyDestroyedIfDone();
}

// ---- Tab management --------------------------------------------------------

void RootWindowMacImpl::OpenNewTab(const std::string& url) {
  REQUIRE_MAIN_THREAD();
  DCHECK(window_);

  // Hide the current active tab.
  if (!tabs_.empty()) {
    auto* old_bw = tabs_[active_tab_idx_]->browser_window();
    if (old_bw->GetBrowser())
      old_bw->GetBrowser()->GetHost()->WasHidden(true);
    NSView* v =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(old_bw->GetWindowHandle());
    if (v) [v setHidden:YES];
  }

  auto tab = std::make_unique<BrowserTabMac>(next_tab_id_++, this,
                                              with_controls_, url);
  active_tab_idx_ = static_cast<int>(tabs_.size());
  tabs_.push_back(std::move(tab));
  RebuildTabBar();

  // Create the browser for the new tab.
  NSView* contentView = [window_ contentView];
  const CGFloat barsH = with_controls_ ? (URLBAR_HEIGHT + TABBAR_HEIGHT) : 0;
  NSRect cb = [contentView bounds];
  CefRect rect(0, 0, static_cast<int>(cb.size.width),
               static_cast<int>(cb.size.height - barsH));

  tabs_[active_tab_idx_]->browser_window()->CreateBrowser(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(contentView), rect,
      cached_settings_, nullptr, cached_request_context_);
}

void RootWindowMacImpl::SwitchToTab(int idx) {
  REQUIRE_MAIN_THREAD();
  if (idx < 0 || idx >= static_cast<int>(tabs_.size())) return;
  if (idx == active_tab_idx_) return;

  // Hide old tab.
  auto* old_bw = tabs_[active_tab_idx_]->browser_window();
  if (old_bw->GetBrowser()) old_bw->GetBrowser()->GetHost()->WasHidden(true);
  NSView* old_v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(old_bw->GetWindowHandle());
  if (old_v) [old_v setHidden:YES];

  active_tab_idx_ = idx;
  auto* new_tab = tabs_[idx].get();
  auto* new_bw = new_tab->browser_window();

  // Show new tab.
  if (new_bw->GetBrowser()) new_bw->GetBrowser()->GetHost()->WasHidden(false);
  NSView* new_v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(new_bw->GetWindowHandle());
  if (new_v) [new_v setHidden:NO];

  // Update toolbar.
  if (with_controls_) {
    [url_textfield_ setStringValue:
        [NSString stringWithUTF8String:new_tab->url().c_str()]];
    [back_button_ setEnabled:new_tab->can_go_back()];
    [forward_button_ setEnabled:new_tab->can_go_forward()];
    [reload_button_ setEnabled:!new_tab->is_loading()];
    [stop_button_ setEnabled:new_tab->is_loading()];
  }
  if (window_) {
    [window_ setTitle:
        [NSString stringWithUTF8String:new_tab->title().c_str()]];
  }

  RebuildTabBar();
}

void RootWindowMacImpl::CloseTab(int idx, bool force) {
  REQUIRE_MAIN_THREAD();
  if (idx < 0 || idx >= static_cast<int>(tabs_.size())) return;

  if (tabs_.size() == 1) {
    // Last tab — close the window via the normal browser-close path.
    auto browser = tabs_[0]->browser_window()->GetBrowser();
    if (browser) browser->GetHost()->CloseBrowser(force);
    return;
  }

  // Move to closing_tabs_ so the object lives until browser teardown completes.
  auto entry = std::move(tabs_[idx]);
  tabs_.erase(tabs_.begin() + idx);

  if (active_tab_idx_ >= static_cast<int>(tabs_.size()))
    active_tab_idx_ = static_cast<int>(tabs_.size()) - 1;

  // Hide the closing browser view.
  NSView* v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(
      entry->browser_window()->GetWindowHandle());
  if (v) [v setHidden:YES];

  closing_tabs_.push_back(std::move(entry));

  SwitchToTab(active_tab_idx_);

  // Force-close the browser (skip beforeunload for non-last tabs).
  auto browser = closing_tabs_.back()->browser_window()->GetBrowser();
  if (browser) browser->GetHost()->CloseBrowser(true);
}

bool RootWindowMacImpl::RequestCloseAllBrowsers(bool force) {
  bool any_pending = false;

  for (auto& tab : tabs_) {
    auto* bw = tab->browser_window();
    if (bw && !bw->IsClosing()) {
      auto browser = bw->GetBrowser();
      if (browser) {
        browser->GetHost()->CloseBrowser(force);
        any_pending = true;
      }
    }
  }

  // OSR/popup path.
  if (browser_window_ && !browser_window_->IsClosing()) {
    auto browser = browser_window_->GetBrowser();
    if (browser) {
      browser->GetHost()->CloseBrowser(force);
      any_pending = true;
    }
  }

  return any_pending;
}

// ---- Tab callbacks from BrowserTabMac -------------------------------------

void RootWindowMacImpl::OnTabReady(BrowserTabMac* tab) {
  REQUIRE_MAIN_THREAD();

  int idx = -1;
  for (int i = 0; i < static_cast<int>(tabs_.size()); ++i) {
    if (tabs_[i].get() == tab) { idx = i; break; }
  }
  if (idx < 0) return;  // already in closing_tabs_, ignore

  if (idx != active_tab_idx_) {
    // This tab was created but is not active — hide and pause immediately.
    auto browser = tab->browser_window()->GetBrowser();
    if (browser) browser->GetHost()->WasHidden(true);
    NSView* v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(
        tab->browser_window()->GetWindowHandle());
    if (v) [v setHidden:YES];
  }
}

void RootWindowMacImpl::OnTabUpdated(BrowserTabMac* tab) {
  REQUIRE_MAIN_THREAD();

  // Always rebuild the tab bar so titles stay current for all tabs.
  RebuildTabBar();

  // Update toolbar/title only for the active tab.
  if (tabs_.empty() || tabs_[active_tab_idx_].get() != tab) return;

  if (with_controls_) {
    [url_textfield_
        setStringValue:[NSString stringWithUTF8String:tab->url().c_str()]];
    [url_textfield_ setEnabled:YES];
    [back_button_ setEnabled:tab->can_go_back()];
    [forward_button_ setEnabled:tab->can_go_forward()];
    [reload_button_ setEnabled:!tab->is_loading()];
    [stop_button_ setEnabled:tab->is_loading()];

    if (!tab->is_loading()) {
      Boolean keyExists = false;
      if (CFPreferencesGetAppBooleanValue(CFSTR("voiceOverOnOffKey"),
                                          CFSTR("com.apple.universalaccess"),
                                          &keyExists)) {
        auto browser = GetBrowser();
        if (browser) browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
      }
    }
  }

  if (window_) {
    [window_
        setTitle:[NSString stringWithUTF8String:tab->title().c_str()]];
  }
}

void RootWindowMacImpl::OnTabDestroyed(BrowserTabMac* tab) {
  REQUIRE_MAIN_THREAD();

  // Check closing_tabs_ first (the common path for non-last tab close).
  for (auto& ct : closing_tabs_) {
    if (ct.get() == tab) {
      // Schedule removal after the call stack unwinds to avoid destroying
      // the BrowserTabMac object while we're inside its method.
      MAIN_POST_CLOSURE(base::BindOnce(
          [](scoped_refptr<RootWindowMacImpl> impl) {
            impl->closing_tabs_.erase(
                std::remove_if(impl->closing_tabs_.begin(),
                               impl->closing_tabs_.end(),
                               [](const std::unique_ptr<BrowserTabMac>& t) {
                                 return !t->is_ready();
                                 // is_ready() stays true even after destroy;
                                 // use a different sentinel.
                               }),
                impl->closing_tabs_.end());
            impl->NotifyDestroyedIfDone();
          },
          scoped_refptr<RootWindowMacImpl>(this)));
      return;
    }
  }

  // Tab was in tabs_ (browser died unexpectedly, e.g. JS window.close()).
  for (int i = 0; i < static_cast<int>(tabs_.size()); ++i) {
    if (tabs_[i].get() == tab) {
      auto entry = std::move(tabs_[i]);
      tabs_.erase(tabs_.begin() + i);

      if (active_tab_idx_ >= static_cast<int>(tabs_.size()))
        active_tab_idx_ = std::max(0, static_cast<int>(tabs_.size()) - 1);

      if (tabs_.empty()) {
        // Last tab gone — close the window.
        MAIN_POST_CLOSURE(base::BindOnce(
            [](scoped_refptr<RootWindowMacImpl> impl) {
              impl->Close(true);
            },
            scoped_refptr<RootWindowMacImpl>(this)));
      } else {
        MAIN_POST_CLOSURE(base::BindOnce(
            [](scoped_refptr<RootWindowMacImpl> impl, int idx,
               std::unique_ptr<BrowserTabMac> dead) {
              impl->SwitchToTab(idx);
              // dead goes out of scope here (after the stack is clear).
            },
            scoped_refptr<RootWindowMacImpl>(this),
            active_tab_idx_,
            std::move(entry)));
      }
      return;
    }
  }
}

// ---- Tab bar ---------------------------------------------------------------

void RootWindowMacImpl::CreateTabBar(NSView* contentView) {
  const CGFloat totalH = [contentView bounds].size.height;
  const CGFloat totalW = [contentView bounds].size.width;
  NSRect barRect = NSMakeRect(0, totalH - TABBAR_HEIGHT, totalW, TABBAR_HEIGHT);

  tab_bar_view_ = [[NSView alloc] initWithFrame:barRect];
#if !__has_feature(objc_arc)
  [tab_bar_view_ autorelease];
#endif
  [tab_bar_view_ setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [tab_bar_view_ setWantsLayer:YES];
  tab_bar_view_.layer.backgroundColor =
      [[NSColor colorWithCalibratedWhite:0.88f alpha:1.f] CGColor];
  [contentView addSubview:tab_bar_view_];

  RebuildTabBar();
}

void RootWindowMacImpl::RebuildTabBar() {
  if (!tab_bar_view_) return;

  for (NSView* v in [[tab_bar_view_ subviews] copy])
    [v removeFromSuperview];

  const CGFloat barW = [tab_bar_view_ bounds].size.width;
  const CGFloat barH = [tab_bar_view_ bounds].size.height;
  const int n = static_cast<int>(tabs_.size());
  const CGFloat plusW = 28;
  const CGFloat availW = barW - plusW - TAB_PADDING * 2;
  const CGFloat tabW = n > 0
      ? std::min<CGFloat>(TAB_MAX_WIDTH,
                          std::max<CGFloat>(TAB_MIN_WIDTH, availW / n))
      : TAB_MAX_WIDTH;

  CGFloat x = TAB_PADDING;
  for (int i = 0; i < n; ++i) {
    const bool active = (i == active_tab_idx_);
    NSString* title =
        [NSString stringWithUTF8String:tabs_[i]->title().c_str()];

    // Tab container.
    NSView* tv = [[NSView alloc] initWithFrame:NSMakeRect(x, 2, tabW, barH - 4)];
#if !__has_feature(objc_arc)
    [tv autorelease];
#endif
    [tv setWantsLayer:YES];
    tv.layer.cornerRadius = 4.f;
    tv.layer.backgroundColor = active
        ? [[NSColor whiteColor] CGColor]
        : [[NSColor colorWithCalibratedWhite:0.78f alpha:1.f] CGColor];
    [tab_bar_view_ addSubview:tv];

    // Title button.
    NSRect tr = NSMakeRect(4, 0, tabW - TAB_CLOSE_SIZE - 8, barH - 4);
    NSButton* tb = [[NSButton alloc] initWithFrame:tr];
#if !__has_feature(objc_arc)
    [tb autorelease];
#endif
    [tb setTitle:title];
    [tb setBezelStyle:NSBezelStyleInline];
    [tb setBordered:NO];
    [tb setAlignment:NSTextAlignmentLeft];
    [tb setFont:[NSFont systemFontOfSize:11.f]];
    [tb setTag:i];
    [tb setTarget:window_delegate_];
    [tb setAction:@selector(tabButtonClicked:)];
    [tv addSubview:tb];

    // Close button.
    const CGFloat cy = (barH - 4 - TAB_CLOSE_SIZE) / 2;
    NSButton* cb = [[NSButton alloc] initWithFrame:
        NSMakeRect(tabW - TAB_CLOSE_SIZE - 4, cy, TAB_CLOSE_SIZE, TAB_CLOSE_SIZE)];
#if !__has_feature(objc_arc)
    [cb autorelease];
#endif
    [cb setTitle:@"×"];
    [cb setBezelStyle:NSBezelStyleInline];
    [cb setBordered:NO];
    [cb setFont:[NSFont systemFontOfSize:11.f]];
    [cb setTag:(1000 + i)];
    [cb setTarget:window_delegate_];
    [cb setAction:@selector(tabCloseButtonClicked:)];
    [tv addSubview:cb];

    x += tabW + 2;
  }

  // "+" button.
  NSButton* plus = [[NSButton alloc] initWithFrame:
      NSMakeRect(x + 2, (barH - 20) / 2, plusW, 20)];
#if !__has_feature(objc_arc)
  [plus autorelease];
#endif
  [plus setTitle:@"+"];
  [plus setBezelStyle:NSBezelStyleSmallSquare];
  [plus setTarget:window_delegate_];
  [plus setAction:@selector(newTabButtonClicked:)];
  [tab_bar_view_ addSubview:plus];
}

// ---- CreateRootWindow ------------------------------------------------------

void RootWindowMacImpl::CreateRootWindow(const CefBrowserSettings& settings,
                                          bool initially_hidden) {
  REQUIRE_MAIN_THREAD();
  DCHECK(!window_);

  CefRect dip_bounds = initial_bounds_;
  if (dip_bounds.width <= 0) dip_bounds.width = 800;
  if (dip_bounds.height <= 0) dip_bounds.height = 600;

  const bool has_controls = !with_osr_ && with_controls_;

  if (is_popup_ && has_controls) dip_bounds.height += URLBAR_HEIGHT + TABBAR_HEIGHT;

  const NSWindowStyleMask style_mask =
      NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

  NSRect frame_rect, content_rect;
  GetNSBoundsInDisplay(dip_bounds, is_popup_, style_mask, false,
                       frame_rect, content_rect);

  window_ = [[NSWindow alloc] initWithContentRect:content_rect
                                        styleMask:style_mask
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  [window_ setTitle:@"cefclient"];
  window_.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];

  window_delegate_ = [[RootWindowDelegate alloc] initWithWindow:window_
                                                  andRootWindow:&root_window_];
  if (!initial_bounds_.IsEmpty())
    window_delegate_.last_visible_bounds = initial_bounds_;

  [window_ setReleasedWhenClosed:NO];

  const cef_color_t bg = MainContext::Get()->GetBackgroundColor();
  [window_ setBackgroundColor:
      [NSColor colorWithCalibratedRed:float(CefColorGetR(bg)) / 255.f
                                green:float(CefColorGetG(bg)) / 255.f
                                 blue:float(CefColorGetB(bg)) / 255.f
                                alpha:1.f]];

  NSView* contentView = [window_ contentView];
  NSRect contentBounds = [contentView bounds];

  if (!with_osr_) [contentView setWantsLayer:YES];

  if (has_controls) {
    const CGFloat browserH = contentBounds.size.height - URLBAR_HEIGHT - TABBAR_HEIGHT;

    // Tab bar (top strip).
    CreateTabBar(contentView);

    // URL bar buttons (strip between tab bar and browser area).
    NSRect br;
    br.origin.y = browserH + (URLBAR_HEIGHT - BUTTON_HEIGHT) / 2;
    br.size.height = BUTTON_HEIGHT;
    br.origin.x = BUTTON_MARGIN;
    br.size.width = BUTTON_WIDTH;

    back_button_ = MakeButton(&br, @"Back", contentView);
    [back_button_ setTarget:window_delegate_];
    [back_button_ setAction:@selector(goBack:)];
    [back_button_ setEnabled:NO];

    forward_button_ = MakeButton(&br, @"Forward", contentView);
    [forward_button_ setTarget:window_delegate_];
    [forward_button_ setAction:@selector(goForward:)];
    [forward_button_ setEnabled:NO];

    reload_button_ = MakeButton(&br, @"Reload", contentView);
    [reload_button_ setTarget:window_delegate_];
    [reload_button_ setAction:@selector(reload:)];
    [reload_button_ setEnabled:NO];

    stop_button_ = MakeButton(&br, @"Stop", contentView);
    [stop_button_ setTarget:window_delegate_];
    [stop_button_ setAction:@selector(stopLoading:)];
    [stop_button_ setEnabled:NO];

    br.origin.x += BUTTON_MARGIN;
    br.size.width = contentBounds.size.width - br.origin.x - BUTTON_MARGIN;
    url_textfield_ = [[NSTextField alloc] initWithFrame:br];
    [contentView addSubview:url_textfield_];
    [url_textfield_ setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [url_textfield_ setTarget:window_delegate_];
    [url_textfield_ setAction:@selector(takeURLStringValueFrom:)];
    [url_textfield_ setEnabled:NO];
    [[url_textfield_ cell] setWraps:NO];
    [[url_textfield_ cell] setScrollable:YES];

    const CefRect cef_rect(0, 0,
                           static_cast<int>(contentBounds.size.width),
                           static_cast<int>(browserH));

    if (!is_popup_) {
      DCHECK(!tabs_.empty());
      tabs_[0]->browser_window()->CreateBrowser(
          CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(contentView), cef_rect,
          settings, nullptr, root_window_.delegate_->GetRequestContext());
      cached_request_context_ = root_window_.delegate_->GetRequestContext();
    } else {
      browser_window_->ShowPopup(
          CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(contentView), 0, 0,
          static_cast<size_t>(contentBounds.size.width),
          static_cast<size_t>(browserH));
    }
  } else {
    // No controls (OSR or windowless).
    if (!is_popup_) {
      if (with_osr_) {
        auto display = CefDisplay::GetDisplayMatchingBounds(dip_bounds, false);
        browser_window_->SetDeviceScaleFactor(display->GetDeviceScaleFactor());
        browser_window_->CreateBrowser(
            CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(contentView),
            CefRect(0, 0, static_cast<int>(contentBounds.size.width),
                    static_cast<int>(contentBounds.size.height)),
            settings, nullptr, root_window_.delegate_->GetRequestContext());
      } else if (!tabs_.empty()) {
        tabs_[0]->browser_window()->CreateBrowser(
            CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(contentView),
            CefRect(0, 0, static_cast<int>(contentBounds.size.width),
                    static_cast<int>(contentBounds.size.height)),
            settings, nullptr, root_window_.delegate_->GetRequestContext());
        cached_request_context_ = root_window_.delegate_->GetRequestContext();
      }
    } else {
      browser_window_->ShowPopup(
          CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(contentView), 0, 0,
          static_cast<size_t>(contentBounds.size.width),
          static_cast<size_t>(contentBounds.size.height));
    }
  }

  [window_ setFrameOrigin:frame_rect.origin];

  if (!initially_hidden) {
    auto mode = RootWindow::ShowNormal;
    if (initial_show_state_ == CEF_SHOW_STATE_MAXIMIZED)
      mode = RootWindow::ShowMaximized;
    else if (initial_show_state_ == CEF_SHOW_STATE_MINIMIZED)
      mode = RootWindow::ShowMinimized;
    Show(mode);
  }

  root_window_.window_created_ = true;
}

// ---- Legacy BrowserWindow::Delegate (OSR / popup path) -------------------

void RootWindowMacImpl::OnBrowserCreated(CefRefPtr<CefBrowser> /*browser*/) {
  REQUIRE_MAIN_THREAD();
  if (is_popup_) CreateRootWindow(CefBrowserSettings(), false);
}

void RootWindowMacImpl::OnBrowserWindowDestroyed() {
  REQUIRE_MAIN_THREAD();
  browser_window_.reset();
  if (!window_destroyed_) Close(true);
  browser_destroyed_ = true;
  NotifyDestroyedIfDone();
}

void RootWindowMacImpl::OnSetAddress(const std::string& url) {
  REQUIRE_MAIN_THREAD();
  if (url_textfield_)
    [url_textfield_ setStringValue:[NSString stringWithUTF8String:url.c_str()]];
}

void RootWindowMacImpl::OnSetTitle(const std::string& title) {
  REQUIRE_MAIN_THREAD();
  if (window_)
    [window_ setTitle:[NSString stringWithUTF8String:title.c_str()]];
}

void RootWindowMacImpl::OnSetFullscreen(bool fullscreen) {
  REQUIRE_MAIN_THREAD();
  CefRefPtr<CefBrowser> browser = GetBrowser();
  if (browser) {
    std::unique_ptr<window_test::WindowTestRunnerMac> runner(
        new window_test::WindowTestRunnerMac());
    if (fullscreen) runner->Maximize(browser);
    else runner->Restore(browser);
  }
}

void RootWindowMacImpl::OnAutoResize(const CefSize& new_size) {
  REQUIRE_MAIN_THREAD();
  if (!window_) return;
  CefRect dip_bounds(0, 0, static_cast<int>(new_size.width),
                     static_cast<int>(new_size.height));
  if (auto sb = GetWindowBoundsInScreen(window_)) {
    dip_bounds.x = (*sb).x;
    dip_bounds.y = (*sb).y;
  }
  NSRect frame_rect, content_rect;
  GetNSBoundsInDisplay(dip_bounds, true, [window_ styleMask], with_controls_,
                       frame_rect, content_rect);
  frame_rect.origin = window_.frame.origin;
  [window_ setFrame:frame_rect display:YES];
  Show(RootWindow::ShowNormal);
}

void RootWindowMacImpl::OnSetLoadingState(bool isLoading, bool canGoBack,
                                           bool canGoForward) {
  REQUIRE_MAIN_THREAD();
  if (!with_controls_) return;
  [url_textfield_ setEnabled:YES];
  [reload_button_ setEnabled:!isLoading];
  [stop_button_ setEnabled:isLoading];
  [back_button_ setEnabled:canGoBack];
  [forward_button_ setEnabled:canGoForward];
}

void RootWindowMacImpl::OnSetDraggableRegions(
    const std::vector<CefDraggableRegion>&) {
  REQUIRE_MAIN_THREAD();
  // TODO: implement draggable regions.
}

void RootWindowMacImpl::NotifyDestroyedIfDone() {
  // For tabbed windows: destroyed when window is gone AND all tabs are gone.
  // For OSR/popup windows: use the legacy browser_destroyed_ flag.
  if (!window_destroyed_) return;
  if (!browser_window_ && !browser_destroyed_) {
    // Tabbed path: wait for closing_tabs_ to empty too.
    if (!tabs_.empty()) return;
    if (!closing_tabs_.empty()) return;
  } else {
    // OSR/popup path.
    if (!browser_destroyed_) return;
  }
  root_window_.delegate_->OnRootWindowDestroyed(&root_window_);
}

// ---- Helpers ---------------------------------------------------------------

BrowserWindowStdMac* RootWindowMacImpl::ActiveBrowserWindowStd() const {
  if (tabs_.empty()) return nullptr;
  return tabs_[active_tab_idx_]->browser_window();
}

BrowserWindow* RootWindowMacImpl::ActiveBrowserWindow() const {
  if (browser_window_) return browser_window_.get();  // OSR path
  return ActiveBrowserWindowStd();
}

// ===========================================================================
// RootWindowMac public methods
// ===========================================================================

RootWindowMac::RootWindowMac(bool use_alloy_style)
    : RootWindow(use_alloy_style) {
  impl_ = new RootWindowMacImpl(*this);
}

RootWindowMac::~RootWindowMac() {}

BrowserWindow* RootWindowMac::browser_window() const {
  return impl_->ActiveBrowserWindow();
}

RootWindow::Delegate* RootWindowMac::delegate() const { return delegate_; }

const OsrRendererSettings* RootWindowMac::osr_settings() const {
  return &impl_->osr_settings_;
}

void RootWindowMac::OpenNewTab(const std::string& url) {
  impl_->OpenNewTab(url);
}

void RootWindowMac::SwitchToTab(int index) { impl_->SwitchToTab(index); }

void RootWindowMac::CloseTab(int index, bool force) {
  impl_->CloseTab(index, force);
}

bool RootWindowMac::RequestCloseAllBrowsers(bool force) {
  return impl_->RequestCloseAllBrowsers(force);
}

void RootWindowMac::Init(RootWindow::Delegate* delegate,
                          std::unique_ptr<RootWindowConfig> config,
                          const CefBrowserSettings& settings) {
  DCHECK(delegate);
  delegate_ = delegate;
  impl_->Init(delegate, std::move(config), settings);
}

void RootWindowMac::InitAsPopup(RootWindow::Delegate* delegate,
                                 bool with_controls, bool with_osr,
                                 const CefPopupFeatures& popupFeatures,
                                 CefWindowInfo& windowInfo,
                                 CefRefPtr<CefClient>& client,
                                 CefBrowserSettings& settings) {
  DCHECK(delegate);
  delegate_ = delegate;
  impl_->InitAsPopup(delegate, with_controls, with_osr, popupFeatures,
                     windowInfo, client, settings);
}

void RootWindowMac::Show(ShowMode mode) { impl_->Show(mode); }
void RootWindowMac::Hide() { impl_->Hide(); }

void RootWindowMac::SetBounds(int x, int y, size_t width, size_t height,
                               bool content_bounds) {
  impl_->SetBounds(x, y, width, height, content_bounds);
}

bool RootWindowMac::DefaultToContentBounds() const {
  return impl_->DefaultToContentBounds();
}

void RootWindowMac::Close(bool force) { impl_->Close(force); }

void RootWindowMac::SetDeviceScaleFactor(float device_scale_factor) {
  impl_->SetDeviceScaleFactor(device_scale_factor);
}

std::optional<float> RootWindowMac::GetDeviceScaleFactor() const {
  return impl_->GetDeviceScaleFactor();
}

CefRefPtr<CefBrowser> RootWindowMac::GetBrowser() const {
  return impl_->GetBrowser();
}

ClientWindowHandle RootWindowMac::GetWindowHandle() const {
  return impl_->GetWindowHandle();
}

bool RootWindowMac::WithWindowlessRendering() const {
  return impl_->WithWindowlessRendering();
}

void RootWindowMac::OnBrowserCreated(CefRefPtr<CefBrowser> browser) {
  impl_->OnBrowserCreated(browser);
}

void RootWindowMac::OnBrowserWindowDestroyed() {
  impl_->OnBrowserWindowDestroyed();
}

void RootWindowMac::OnSetAddress(const std::string& url) {
  impl_->OnSetAddress(url);
}

void RootWindowMac::OnSetTitle(const std::string& title) {
  impl_->OnSetTitle(title);
}

void RootWindowMac::OnSetFullscreen(bool fullscreen) {
  impl_->OnSetFullscreen(fullscreen);
}

void RootWindowMac::OnAutoResize(const CefSize& new_size) {
  impl_->OnAutoResize(new_size);
}

void RootWindowMac::OnSetLoadingState(bool isLoading, bool canGoBack,
                                       bool canGoForward) {
  impl_->OnSetLoadingState(isLoading, canGoBack, canGoForward);
}

void RootWindowMac::OnSetDraggableRegions(
    const std::vector<CefDraggableRegion>& regions) {
  impl_->OnSetDraggableRegions(regions);
}

void RootWindowMac::OnContentsBounds(const CefRect& new_bounds) {
  RootWindow::SetBounds(new_bounds, DefaultToContentBounds());
}

void RootWindowMac::OnNativeWindowClosed() { impl_->OnNativeWindowClosed(); }

}  // namespace client

// ===========================================================================
// RootWindowDelegate implementation
// ===========================================================================

@implementation RootWindowDelegate

@synthesize root_window = root_window_;
@synthesize last_visible_bounds = last_visible_bounds_;
@synthesize force_close = force_close_;

- (id)initWithWindow:(NSWindow*)window
       andRootWindow:(client::RootWindowMac*)root_window {
  if (self = [super init]) {
    window_ = window;
    [window_ setDelegate:self];
    root_window_ = root_window;
    force_close_ = false;

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationDidHide:)
               name:NSApplicationDidHideNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(applicationDidUnhide:)
               name:NSApplicationDidUnhideNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
#if !__has_feature(objc_arc)
  [super dealloc];
#endif
}

- (IBAction)goBack:(id)sender {
  if (auto b = root_window_->GetBrowser()) b->GoBack();
}

- (IBAction)goForward:(id)sender {
  if (auto b = root_window_->GetBrowser()) b->GoForward();
}

- (IBAction)reload:(id)sender {
  if (auto b = root_window_->GetBrowser()) b->Reload();
}

- (IBAction)stopLoading:(id)sender {
  if (auto b = root_window_->GetBrowser()) b->StopLoad();
}

- (IBAction)takeURLStringValueFrom:(NSTextField*)sender {
  auto browser = root_window_->GetBrowser();
  if (!browser) return;
  NSString* url = [sender stringValue];
  NSURL* tmp = [NSURL URLWithString:url];
  if (tmp && ![tmp scheme]) url = [@"http://" stringByAppendingString:url];
  browser->GetMainFrame()->LoadURL([url UTF8String]);
}

- (IBAction)tabButtonClicked:(id)sender {
  root_window_->SwitchToTab((int)[(NSButton*)sender tag]);
}

- (IBAction)tabCloseButtonClicked:(id)sender {
  root_window_->CloseTab((int)[(NSButton*)sender tag] - 1000, /*force=*/true);
}

- (IBAction)newTabButtonClicked:(id)sender {
  root_window_->OpenNewTab("about:blank");
}

- (void)windowDidBecomeKey:(NSNotification*)notification {
  if (auto* bw = root_window_->browser_window()) bw->SetFocus(true);
  root_window_->delegate()->OnRootWindowActivated(root_window_);
}

- (void)windowDidResignKey:(NSNotification*)notification {
  if (auto* bw = root_window_->browser_window()) bw->SetFocus(false);
}

- (void)windowDidMiniaturize:(NSNotification*)notification {
  if (auto* bw = root_window_->browser_window()) bw->Hide();
}

- (void)windowDidDeminiaturize:(NSNotification*)notification {
  if (auto* bw = root_window_->browser_window()) bw->Show();
}

- (void)windowDidResize:(NSNotification*)notification {
  if (auto dip = client::GetWindowBoundsInScreen(window_))
    last_visible_bounds_ = dip;
}

- (void)windowDidMove:(NSNotification*)notification {
  if (auto dip = client::GetWindowBoundsInScreen(window_))
    last_visible_bounds_ = dip;
  if (root_window_->WithWindowlessRendering() &&
      root_window_->osr_settings()->real_screen_bounds) {
    if (auto* bw = root_window_->browser_window()) {
      if (auto b = bw->GetBrowser())
        b->GetHost()->NotifyScreenInfoChanged();
    }
  }
}

- (void)applicationDidHide:(NSNotification*)notification {
  if (![window_ isMiniaturized]) {
    if (auto* bw = root_window_->browser_window()) bw->Hide();
  }
}

- (void)applicationDidUnhide:(NSNotification*)notification {
  if (![window_ isMiniaturized]) {
    if (auto* bw = root_window_->browser_window()) bw->Show();
  }
}

- (BOOL)windowShouldClose:(NSWindow*)window {
  if (!force_close_) {
    // Ask all tabs to close; if any are still pending cancel the native close.
    if (root_window_->RequestCloseAllBrowsers(false)) return NO;
  }

  // Save window restore position.
  std::optional<CefRect> dip_bounds;
  cef_show_state_t show_state = CEF_SHOW_STATE_NORMAL;
  if ([window_ isMiniaturized]) show_state = CEF_SHOW_STATE_MINIMIZED;
  else if ([window_ isZoomed]) show_state = CEF_SHOW_STATE_MAXIMIZED;
  else dip_bounds = client::GetWindowBoundsInScreen(window_);

  if (!dip_bounds) dip_bounds = last_visible_bounds_;
  client::prefs::SaveWindowRestorePreferences(show_state, dip_bounds);

  [self cleanup];
  return YES;
}

- (void)cleanup {
  window_.delegate = nil;
  window_.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
#if !__has_feature(objc_arc)
  [window_ autorelease];
#endif
  window_ = nil;
  root_window_->OnNativeWindowClosed();
}

@end
