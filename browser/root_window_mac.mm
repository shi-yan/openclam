// Copyright (c) 2015 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "browser/base_client_handler.h"
#include "browser/root_window_mac.h"

#include <Cocoa/Cocoa.h>

#include <algorithm>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/views/cef_display.h"
#include "browser/browser_window_osr_mac.h"
#include "browser/browser_window_std_mac.h"
#include "browser/client_prefs.h"
#include "browser/main_context.h"
#include "browser/osr_renderer_settings.h"
#include "browser/root_window_manager.h"
#include "browser/temp_window.h"
#include "browser/util_mac.h"
#include "browser/window_test_runner_mac.h"
#include "browser/openclam_scheme_handler.h"
#include "shared/browser/main_message_loop.h"
#include "shared/common/client_switches.h"

// Forward-declare the C++ impl so ObjC classes can hold a pointer to it.
namespace client { class RootWindowMacImpl; }

// ===========================================================================
// ObjC class interfaces
// ===========================================================================

// ---------------------------------------------------------------------------
// PanelSplitViewDelegate — draggable-divider constraints for the three panels.
// ---------------------------------------------------------------------------

@interface PanelSplitViewDelegate : NSObject <NSSplitViewDelegate>
// assign: the views are owned by the split view; no retain cycle.
@property(nonatomic, assign) NSView* leftPanelView;
@property(nonatomic, assign) NSView* rightPanelView;
@end

@implementation PanelSplitViewDelegate

// Only the center panel grows/shrinks when the window resizes.
- (BOOL)splitView:(NSSplitView*)splitView
    shouldAdjustSizeOfSubview:(NSView*)subview {
  return subview != self.leftPanelView && subview != self.rightPanelView;
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMinCoordinate:(CGFloat)proposedMinimumPosition
              ofSubviewAt:(NSInteger)dividerIndex {
  if (dividerIndex == 0) return 80.0;  // left panel minimum width
  // Right divider: center panel must be ≥ 200 px.
  return splitView.subviews[0].frame.size.width +
         splitView.dividerThickness + 200.0;
}

- (CGFloat)splitView:(NSSplitView*)splitView
    constrainMaxCoordinate:(CGFloat)proposedMaximumPosition
              ofSubviewAt:(NSInteger)dividerIndex {
  const CGFloat totalW = splitView.frame.size.width;
  const CGFloat dt = splitView.dividerThickness;
  if (dividerIndex == 0) {
    // Keep center ≥ 200 and right ≥ 80.
    return totalW - dt - 200.0 - dt - 80.0;
  }
  // Right divider: right panel minimum width 80 px.
  return totalW - dt - 80.0;
}

// Allow both side panels to be collapsed to zero width.
- (BOOL)splitView:(NSSplitView*)splitView
    canCollapseSubview:(NSView*)subview {
  return subview == self.leftPanelView || subview == self.rightPanelView;
}

@end

// ---------------------------------------------------------------------------

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
- (IBAction)toggleLeftPanel:(id)sender;
- (IBAction)toggleRightPanel:(id)sender;

// Set by CreateRootWindow so toggle actions can reach the split view.
@property(nonatomic, assign) NSSplitView* splitView;
@property(nonatomic, assign) NSView* leftPanelView;
@property(nonatomic, assign) NSView* rightPanelView;
@end

namespace client {

namespace {

// Simple base64 encoder for binary → ASCII.
static std::string Base64Encode(const unsigned char* data, size_t len) {
  static const char kChars[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((len + 2) / 3) * 4);
  for (size_t i = 0; i < len; i += 3) {
    unsigned int v = static_cast<unsigned int>(data[i]) << 16;
    if (i + 1 < len) v |= static_cast<unsigned int>(data[i + 1]) << 8;
    if (i + 2 < len) v |= static_cast<unsigned int>(data[i + 2]);
    out += kChars[(v >> 18) & 0x3F];
    out += kChars[(v >> 12) & 0x3F];
    out += (i + 1 < len) ? kChars[(v >> 6) & 0x3F] : '=';
    out += (i + 2 < len) ? kChars[(v >> 0) & 0x3F] : '=';
  }
  return out;
}

#define BUTTON_HEIGHT 22
#define BUTTON_WIDTH 72
#define BUTTON_MARGIN 8
#define URLBAR_HEIGHT 32

// Left panel: sessions Vue browser.
#define LEFT_PANEL_WIDTH 220
// Right panel: tabs+chat Vue browser.
#define RIGHT_PANEL_WIDTH 280

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
                               bool set_origin);

void GetNSBoundsInDisplay(const CefRect& dip_bounds,
                          bool use_content_bounds,
                          NSWindowStyleMask style_mask,
                          bool add_controls,
                          NSRect& frame_rect,
                          NSRect& content_rect);

}  // namespace

// ===========================================================================
// PanelBrowserDelegate — no-op delegate for Vue sidebar panel browsers.
// ===========================================================================

class PanelBrowserDelegate : public BrowserWindow::Delegate {
 public:
  // Call before CreateBrowser so OnBrowserCreated can size the browser NSView.
  void SetParentView(NSView* parent) { parent_view_ = parent; }
  void SetDestroyedCallback(std::function<void()> cb) {
    destroyed_cb_ = std::move(cb);
  }

  bool UseAlloyStyle() const override { return true; }

  // CEF creates the browser NSView asynchronously.  Force it to fill the
  // parent container so there is no gap at the top or sides.
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser) override {
    if (!parent_view_) return;
    NSView* bv = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(
        browser->GetHost()->GetWindowHandle());
    if (bv) {
      [bv setFrame:[parent_view_ bounds]];
      [bv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    }
  }

  void OnBrowserWindowDestroyed() override {
    if (destroyed_cb_) destroyed_cb_();
  }
  void OnSetAddress(const std::string&) override {}
  void OnSetTitle(const std::string&) override {}
  void OnSetFullscreen(bool) override {}
  void OnAutoResize(const CefSize&) override {}
  void OnContentsBounds(const CefRect&) override {}
  void OnSetLoadingState(bool, bool, bool) override {}
  void OnSetDraggableRegions(const std::vector<CefDraggableRegion>&) override {}

 private:
  NSView* __unsafe_unretained parent_view_ = nil;
  std::function<void()> destroyed_cb_;
};

// ===========================================================================
// BrowserTabMac
// ===========================================================================

// Each tab IS its own BrowserWindow::Delegate.  It owns one
// BrowserWindowStdMac and stores per-tab state (title, url, loading, …).
// When state changes it calls parent_->OnTabUpdated(this).
class BrowserTabMac : public BrowserWindow::Delegate {
 public:
  BrowserTabMac(int tab_id, RootWindowMacImpl* parent,
                bool with_controls, const std::string& url)
      : tab_id_(tab_id), parent_(parent) {
    browser_window_.reset(
        new BrowserWindowStdMac(this, with_controls, url));
  }

  int tab_id() const { return tab_id_; }
  BrowserWindowStdMac* browser_window() { return browser_window_.get(); }

  const std::string& title()            const { return title_; }
  const std::string& url()              const { return url_; }
  const std::string& favicon_data_url() const { return favicon_data_url_; }
  bool is_ready()       const { return ready_; }
  bool is_loading()     const { return is_loading_; }
  bool can_go_back()    const { return can_go_back_; }
  bool can_go_forward() const { return can_go_forward_; }

  bool UseAlloyStyle() const override;

  void OnBrowserCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBrowserWindowDestroyed() override;

  void OnSetTitle(const std::string& title) override {
    title_ = title.empty() ? "New Tab" : title;
    NotifyParent();
  }

  void OnSetAddress(const std::string& url) override {
    url_ = url;
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

  void OnSetFavicon(CefRefPtr<CefImage> image) override {
    if (!image || image->IsEmpty()) return;
    int pw = 0, ph = 0;
    CefRefPtr<CefBinaryValue> png = image->GetAsPNG(1.0f, true, pw, ph);
    if (!png) return;
    size_t sz = png->GetSize();
    std::vector<unsigned char> buf(sz);
    png->GetData(buf.data(), sz, 0);
    favicon_data_url_ = "data:image/png;base64," + Base64Encode(buf.data(), sz);
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
  std::string favicon_data_url_;
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

  // Vue panel helpers.
  void CreateVuePanels();
  void PostNavStateToVue(BrowserTabMac* tab);

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

  // Vue sidebar panels (CEF browsers pointing at local HTML files).
  NSSplitView* split_view_ = nil;
  PanelSplitViewDelegate* split_delegate_ = nil;
  NSView* left_panel_view_ = nil;      // sessions Vue browser container
  NSView* browser_area_view_ = nil;    // center container (url bar + web content)
  NSView* right_panel_view_ = nil;     // tabs+chat Vue browser container
  PanelBrowserDelegate left_panel_delegate_;
  PanelBrowserDelegate right_panel_delegate_;
  std::unique_ptr<BrowserWindowStdMac> left_panel_browser_;
  std::unique_ptr<BrowserWindowStdMac> right_panel_browser_;

  NSButton* back_button_ = nil;
  NSButton* forward_button_ = nil;
  NSButton* reload_button_ = nil;
  NSButton* stop_button_ = nil;
  NSTextField* url_textfield_ = nil;

  bool window_destroyed_ = false;
  bool browser_destroyed_ = false;  // used for OSR/popup path only
  // Panel browsers destroyed flags (true = destroyed or never created).
  bool left_panel_destroyed_ = true;
  bool right_panel_destroyed_ = true;
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
#if !__has_feature(objc_arc)
  [split_delegate_ release];
#endif
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

  // Browser fills the full browser_area_view_ (no native toolbar).
  NSRect bab = [browser_area_view_ bounds];
  CefRect rect(0, 0,
               static_cast<int>(bab.size.width),
               static_cast<int>(bab.size.height));

  tabs_[active_tab_idx_]->browser_window()->CreateBrowser(
      CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browser_area_view_), rect,
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

  // Push the new tab's URL and nav state to the Vue right panel.
  PostNavStateToVue(new_tab);
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

  // Force-close Vue panel browsers (no beforeunload handlers).
  // Don't count them in any_pending — they must not block the native close.
  if (left_panel_browser_ && !left_panel_browser_->IsClosing()) {
    auto browser = left_panel_browser_->GetBrowser();
    if (browser) browser->GetHost()->CloseBrowser(true);
  }
  if (right_panel_browser_ && !right_panel_browser_->IsClosing()) {
    auto browser = right_panel_browser_->GetBrowser();
    if (browser) browser->GetHost()->CloseBrowser(true);
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

  // Give the browser view a fill-parent autoresizing mask so it grows/shrinks
  // with browser_area_view_ when the window or sidebar is resized.
  NSView* v = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(
      tab->browser_window()->GetWindowHandle());
  if (v) {
    [v setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  }

  if (idx != active_tab_idx_) {
    // This tab was created but is not active — hide and pause immediately.
    auto browser = tab->browser_window()->GetBrowser();
    if (browser) browser->GetHost()->WasHidden(true);
    if (v) [v setHidden:YES];
  }
}

void RootWindowMacImpl::OnTabUpdated(BrowserTabMac* tab) {
  REQUIRE_MAIN_THREAD();

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

  // Push URL + nav buttons state to the Vue right panel.
  PostNavStateToVue(tab);
}

void RootWindowMacImpl::OnTabDestroyed(BrowserTabMac* tab) {
  REQUIRE_MAIN_THREAD();

  // Check closing_tabs_ first (the common path for non-last tab close).
  for (auto& ct : closing_tabs_) {
    if (ct.get() == tab) {
      MAIN_POST_CLOSURE(base::BindOnce(
          [](scoped_refptr<RootWindowMacImpl> impl, BrowserTabMac* dead) {
            impl->closing_tabs_.erase(
                std::remove_if(impl->closing_tabs_.begin(),
                               impl->closing_tabs_.end(),
                               [dead](const std::unique_ptr<BrowserTabMac>& t) {
                                 return t.get() == dead;
                               }),
                impl->closing_tabs_.end());
            impl->NotifyDestroyedIfDone();
          },
          scoped_refptr<RootWindowMacImpl>(this), tab));
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
            },
            scoped_refptr<RootWindowMacImpl>(this),
            active_tab_idx_,
            std::move(entry)));
      }
      return;
    }
  }
}


// Escape a string for use inside a JSON string literal (double-quoted).
static std::string JsEscapeJson(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 4);
  for (unsigned char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      default:   out += static_cast<char>(c);
    }
  }
  return out;
}

// Post a nav-state update to the Vue right panel.
void RootWindowMacImpl::PostNavStateToVue(BrowserTabMac* tab) {
  if (!right_panel_browser_ || !right_panel_browser_->GetBrowser()) return;
  CefRefPtr<CefFrame> frame =
      right_panel_browser_->GetBrowser()->GetMainFrame();
  if (!frame) return;

  std::string payload =
      "{\"url\":\"" + JsEscapeJson(tab->url()) + "\","
      "\"title\":\"" + JsEscapeJson(tab->title()) + "\","
      "\"faviconDataUrl\":\"" + tab->favicon_data_url() + "\","
      "\"canGoBack\":" + (tab->can_go_back()    ? "true" : "false") + ","
      "\"canGoForward\":" + (tab->can_go_forward() ? "true" : "false") + ","
      "\"isLoading\":" + (tab->is_loading()     ? "true" : "false") + "}";

  std::string js =
      "if(window.__openclam_post)"
      "window.__openclam_post({type:\"active-nav-state\",payload:" + payload + "});";
  frame->ExecuteJavaScript(js, frame->GetURL(), 0);
}

// ---- Vue panel views (layout + browser creation handled in CreateRootWindow)

void RootWindowMacImpl::CreateVuePanels() {
  CGColorRef kPanelBg =
      [NSColor colorWithCalibratedWhite:0.1f alpha:1.f].CGColor;

  left_panel_view_ = [[NSView alloc] init];
#if !__has_feature(objc_arc)
  [left_panel_view_ autorelease];
#endif
  [left_panel_view_ setWantsLayer:YES];
  left_panel_view_.layer.backgroundColor = kPanelBg;

  right_panel_view_ = [[NSView alloc] init];
#if !__has_feature(objc_arc)
  [right_panel_view_ autorelease];
#endif
  [right_panel_view_ setWantsLayer:YES];
  right_panel_view_.layer.backgroundColor = kPanelBg;
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

  if (is_popup_ && has_controls) dip_bounds.height += URLBAR_HEIGHT;

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
  // Force dark appearance for the entire window (title bar, controls, etc.).
  window_.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

  window_delegate_ = [[RootWindowDelegate alloc] initWithWindow:window_
                                                  andRootWindow:&root_window_];
  if (!initial_bounds_.IsEmpty())
    window_delegate_.last_visible_bounds = initial_bounds_;

  [window_ setReleasedWhenClosed:NO];

  // Dark window background — fills any gaps between native subviews.
  [window_ setBackgroundColor:[NSColor colorWithCalibratedWhite:0.1f alpha:1.f]];

  NSView* contentView = [window_ contentView];
  NSRect contentBounds = [contentView bounds];

  if (!with_osr_) [contentView setWantsLayer:YES];

  // ── Titlebar accessory: panel toggle buttons (left | right sidebar) ───────
  if (has_controls && !is_popup_) {
    // Container view for the two buttons placed at the trailing edge.
    NSView* accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 60, 28)];

    // Helper: create a compact icon button using an SF Symbol name.
    auto makeIconBtn = ^NSButton*(NSString* symbolName, SEL action, CGFloat x) {
      NSButton* btn = [[NSButton alloc] initWithFrame:NSMakeRect(x, 3, 26, 22)];
      btn.bezelStyle = NSBezelStyleAccessoryBarAction;
      btn.buttonType = NSButtonTypePushOnPushOff;
      btn.bordered   = NO;
      btn.state      = NSControlStateValueOn;  // panels visible by default

      if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration* cfg =
            [NSImageSymbolConfiguration
                configurationWithPointSize:13
                                    weight:NSFontWeightRegular];
        btn.image = [NSImage imageWithSystemSymbolName:symbolName
                                  accessibilityDescription:nil];
        btn.image = [btn.image imageWithSymbolConfiguration:cfg];
      } else {
        // Fallback: text label for older macOS.
        btn.title     = (x < 10) ? @"⊟" : @"⊞";
        btn.font      = [NSFont systemFontOfSize:13];
      }

      btn.contentTintColor = [NSColor colorWithWhite:0.65 alpha:1.0];
      btn.target  = window_delegate_;
      btn.action  = action;
      [accessory addSubview:btn];
      return btn;
    };

    makeIconBtn(@"sidebar.left",  @selector(toggleLeftPanel:),  2);
    makeIconBtn(@"sidebar.right", @selector(toggleRightPanel:), 32);

    NSTitlebarAccessoryViewController* acc =
        [[NSTitlebarAccessoryViewController alloc] init];
    acc.view = accessory;
    acc.layoutAttribute = NSLayoutAttributeTrailing;
    [window_ addTitlebarAccessoryViewController:acc];
  }

  if (has_controls) {
    // Create Vue sidebar panel views (no layout yet).
    CreateVuePanels();

    // Center panel: url bar + web content browser.
    browser_area_view_ = [[NSView alloc] init];
#if !__has_feature(objc_arc)
    [browser_area_view_ autorelease];
#endif
    [browser_area_view_ setWantsLayer:YES];
    browser_area_view_.layer.backgroundColor =
        [NSColor colorWithCalibratedWhite:0.12f alpha:1.f].CGColor;

    // NSSplitView holds all three panels with draggable dividers.
    split_view_ = [[NSSplitView alloc] init];
#if !__has_feature(objc_arc)
    [split_view_ autorelease];
#endif
    [split_view_ setVertical:YES];
    [split_view_ setDividerStyle:NSSplitViewDividerStyleThin];
    [split_view_ setTranslatesAutoresizingMaskIntoConstraints:NO];
    [contentView addSubview:split_view_];
    [NSLayoutConstraint activateConstraints:@[
      [split_view_.leadingAnchor
          constraintEqualToAnchor:contentView.leadingAnchor],
      [split_view_.trailingAnchor
          constraintEqualToAnchor:contentView.trailingAnchor],
      [split_view_.topAnchor
          constraintEqualToAnchor:contentView.topAnchor],
      [split_view_.bottomAnchor
          constraintEqualToAnchor:contentView.bottomAnchor],
    ]];

    // Add panels: left | center | right.
    [split_view_ addSubview:left_panel_view_];
    [split_view_ addSubview:browser_area_view_];
    [split_view_ addSubview:right_panel_view_];

    // Delegate keeps side panels fixed-width during window resize.
    // Not autoreleased: stored as a member to outlive the split view's
    // weak delegate reference.
    split_delegate_ = [[PanelSplitViewDelegate alloc] init];
    split_delegate_.leftPanelView  = left_panel_view_;
    split_delegate_.rightPanelView = right_panel_view_;
    split_view_.delegate = split_delegate_;

    // Wire up toggle actions on the window delegate.
    window_delegate_.splitView      = split_view_;
    window_delegate_.leftPanelView  = left_panel_view_;
    window_delegate_.rightPanelView = right_panel_view_;

    // First layout pass to get real split_view_ frame.
    [contentView layoutSubtreeIfNeeded];

    // Set initial divider positions.
    [split_view_ setPosition:LEFT_PANEL_WIDTH ofDividerAtIndex:0];
    const CGFloat totalW = split_view_.frame.size.width;
    [split_view_ setPosition:(totalW - RIGHT_PANEL_WIDTH) ofDividerAtIndex:1];

    // Second layout pass so panel bounds reflect the divider positions.
    [contentView layoutSubtreeIfNeeded];

    // Read actual frames for CEF browser creation.
    const NSRect leftBounds   = [left_panel_view_  bounds];
    const NSRect rightBounds  = [right_panel_view_ bounds];
    const NSRect centerBounds = [browser_area_view_ bounds];
    const CGFloat browserAreaW = centerBounds.size.width;
    const CGFloat contentH     = centerBounds.size.height;
    const CGFloat urlH         = URLBAR_HEIGHT;
    const CGFloat browserH     = contentH - urlH;

    // Give each delegate its parent so OnBrowserCreated fills the view.
    left_panel_delegate_.SetParentView(left_panel_view_);
    right_panel_delegate_.SetParentView(right_panel_view_);

    // Track panel browser destruction so NotifyDestroyedIfDone can wait.
    left_panel_destroyed_ = false;
    right_panel_destroyed_ = false;
    {
      scoped_refptr<RootWindowMacImpl> self(this);
      left_panel_delegate_.SetDestroyedCallback([self]() {
        REQUIRE_MAIN_THREAD();
        self->left_panel_destroyed_ = true;
        self->NotifyDestroyedIfDone();
      });
      right_panel_delegate_.SetDestroyedCallback([self]() {
        REQUIRE_MAIN_THREAD();
        self->right_panel_destroyed_ = true;
        self->NotifyDestroyedIfDone();
      });
    }

    // Build openclam://ui/ URLs served by the custom scheme handler.
    const std::string kScheme =
        std::string(openclam_scheme::kSchemeName) + "://ui";
    const std::string sessions_url  = kScheme + "/sessions/index.html";
    const std::string tabs_chat_url = kScheme + "/tabs_chat/index.html";

    // Create sessions panel browser (left).
    left_panel_browser_.reset(new BrowserWindowStdMac(
        &left_panel_delegate_, /*with_controls=*/false, sessions_url));
    left_panel_browser_->CreateBrowser(
        CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(left_panel_view_),
        CefRect(0, 0,
                static_cast<int>(leftBounds.size.width),
                static_cast<int>(leftBounds.size.height)),
        settings, nullptr,
        root_window_.delegate_->GetRequestContext());

    // Create tabs+chat panel browser (right).
    right_panel_browser_.reset(new BrowserWindowStdMac(
        &right_panel_delegate_, /*with_controls=*/false, tabs_chat_url));
    right_panel_browser_->CreateBrowser(
        CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(right_panel_view_),
        CefRect(0, 0,
                static_cast<int>(rightBounds.size.width),
                static_cast<int>(rightBounds.size.height)),
        settings, nullptr,
        root_window_.delegate_->GetRequestContext());

    // Wire up nav commands from the Vue right panel to the active content tab.
    {
      scoped_refptr<RootWindowMacImpl> self(this);
      client::BaseClientHandler::SetNavCommandCallback(
          [self](const std::string& cmd) {
            if (cmd == "back") {
              if (auto b = self->GetBrowser()) b->GoBack();
            } else if (cmd == "forward") {
              if (auto b = self->GetBrowser()) b->GoForward();
            } else if (cmd == "reload") {
              if (auto b = self->GetBrowser()) b->Reload();
            } else if (cmd.compare(0, 5, "load:") == 0) {
              std::string url = cmd.substr(5);
              if (auto b = self->GetBrowser())
                b->GetMainFrame()->LoadURL(url);
            } else if (cmd == "new-tab") {
              self->OpenNewTab("about:blank");
            } else if (cmd.compare(0, 7, "switch:") == 0) {
              int idx = std::stoi(cmd.substr(7));
              self->SwitchToTab(idx);
            } else if (cmd.compare(0, 6, "close:") == 0) {
              int idx = std::stoi(cmd.substr(6));
              self->CloseTab(idx, false);
            }
          });
    }

    // Navigation is handled by the Vue right panel — no native toolbar needed.
    // The browser content fills the full browser_area_view_ height.
    const CefRect cef_rect(0, 0,
                           static_cast<int>(browserAreaW),
                           static_cast<int>(contentH));

    if (!is_popup_) {
      DCHECK(!tabs_.empty());
      tabs_[0]->browser_window()->CreateBrowser(
          CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browser_area_view_), cef_rect,
          settings, nullptr, root_window_.delegate_->GetRequestContext());
      cached_request_context_ = root_window_.delegate_->GetRequestContext();
    } else {
      browser_window_->ShowPopup(
          CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(browser_area_view_), 0, 0,
          static_cast<size_t>(browserAreaW),
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
    if (fullscreen)
      runner->Maximize(browser);
    else
      runner->Restore(browser);
  }
}

void RootWindowMacImpl::OnAutoResize(const CefSize& new_size) {
  REQUIRE_MAIN_THREAD();
  if (!window_) return;

  NSSize size = {static_cast<CGFloat>(new_size.width),
                 static_cast<CGFloat>(new_size.height)};
  if (with_controls_) {
    size.height += URLBAR_HEIGHT;
    size.width += LEFT_PANEL_WIDTH + RIGHT_PANEL_WIDTH;
  }
  NSRect frame = [window_ frame];
  frame.origin.y -= size.height - frame.size.height;
  frame.size = [window_ frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)].size;
  [window_ setFrame:frame display:YES];
}

void RootWindowMacImpl::OnSetLoadingState(bool isLoading,
                                           bool canGoBack,
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
    // Tabbed path: wait for content tabs and panel browsers to finish closing.
    if (!tabs_.empty()) return;
    if (!closing_tabs_.empty()) return;
  } else {
    // OSR/popup path.
    if (!browser_destroyed_) return;
  }
  // Always wait for Vue panel browsers to close before signalling destroyed.
  if (!left_panel_destroyed_ || !right_panel_destroyed_) return;
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
// Utility functions (defined here so they can reference constants above)
// ===========================================================================

namespace {

NSRect ClampNSBoundsToWorkArea(const NSRect& frame_bounds,
                               const CefRect& display_bounds,
                               bool set_origin) {
  NSRect result = frame_bounds;
  if (set_origin) {
    result.origin.x = std::max(result.origin.x,
                                static_cast<CGFloat>(display_bounds.x));
    result.origin.y = std::max(result.origin.y,
                                static_cast<CGFloat>(display_bounds.y));
  }
  if (result.size.width > display_bounds.width)
    result.size.width = display_bounds.width;
  if (result.size.height > display_bounds.height)
    result.size.height = display_bounds.height;
  return result;
}

void GetNSBoundsInDisplay(const CefRect& dip_bounds,
                          bool use_content_bounds,
                          NSWindowStyleMask style_mask,
                          bool add_controls,
                          NSRect& frame_rect,
                          NSRect& content_rect) {
  const int x = dip_bounds.x;
  const int y = dip_bounds.y;
  const int width = dip_bounds.width > 0 ? dip_bounds.width : 800;
  const int height = dip_bounds.height > 0 ? dip_bounds.height : 600;

  NSScreen* screen = [NSScreen mainScreen];
  NSRect screen_rect = [screen visibleFrame];

  if (use_content_bounds) {
    content_rect = NSMakeRect(x, y, width, height);
    frame_rect = [NSWindow frameRectForContentRect:content_rect
                                         styleMask:style_mask];
  } else {
    frame_rect = NSMakeRect(x, y, width, height);
    content_rect = [NSWindow contentRectForFrameRect:frame_rect
                                           styleMask:style_mask];
  }

  // Clamp to visible screen.
  if (frame_rect.size.width > screen_rect.size.width)
    frame_rect.size.width = screen_rect.size.width;
  if (frame_rect.size.height > screen_rect.size.height)
    frame_rect.size.height = screen_rect.size.height;

  // Re-derive content rect after potential size clamp.
  content_rect = [NSWindow contentRectForFrameRect:frame_rect
                                         styleMask:style_mask];
}

}  // namespace

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

- (IBAction)toggleLeftPanel:(id)sender {
  if (!_splitView || !_leftPanelView) return;
  BOOL collapsed = [_splitView isSubviewCollapsed:_leftPanelView];
  if (collapsed) {
    [_splitView setPosition:LEFT_PANEL_WIDTH ofDividerAtIndex:0];
  } else {
    [_splitView setPosition:0 ofDividerAtIndex:0];
  }
  // Update button state if it is an NSButton.
  if ([sender isKindOfClass:[NSButton class]]) {
    NSButton* btn = (NSButton*)sender;
    btn.state = collapsed ? NSControlStateValueOn : NSControlStateValueOff;
  }
}

- (IBAction)toggleRightPanel:(id)sender {
  if (!_splitView || !_rightPanelView) return;
  const CGFloat totalW = _splitView.frame.size.width;
  BOOL collapsed = [_splitView isSubviewCollapsed:_rightPanelView];
  if (collapsed) {
    [_splitView setPosition:(totalW - RIGHT_PANEL_WIDTH) ofDividerAtIndex:1];
  } else {
    [_splitView setPosition:totalW ofDividerAtIndex:1];
  }
  if ([sender isKindOfClass:[NSButton class]]) {
    NSButton* btn = (NSButton*)sender;
    btn.state = collapsed ? NSControlStateValueOn : NSControlStateValueOff;
  }
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

