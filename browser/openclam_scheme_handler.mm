// Copyright (c) 2025 OpenClam Authors. All rights reserved.
//
// Custom URL scheme handler for the "openclam://" scheme.
//
// Security model
// --------------
// Only two URL hosts are served:
//
//   openclam://ui/<app>/<path>
//     Serves static files from the app bundle's Resources/frontend/<app>/
//     directory.  Only files that actually exist inside that subtree are
//     returned; path-traversal sequences ("..") are rejected.
//
//   openclam://agent/<id>
//     (Reserved for future use.)  Will serve agent-generated HTML/CSS/JS
//     kept in an in-memory registry — no filesystem access at all.
//
// No other host/path combinations are served (404).

#include "browser/openclam_scheme_handler.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/cef_parser.h"
#include "include/cef_request.h"
#include "include/cef_resource_handler.h"
#include "include/cef_response.h"
#include "include/cef_scheme.h"
#include "include/cef_stream.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_stream_resource_handler.h"

#if defined(OS_MAC)
#include <Foundation/Foundation.h>
#endif

namespace client::openclam_scheme {

const char kSchemeName[] = "openclam";

namespace {

// Returns the MIME type for a file based on its extension.
std::string MimeTypeForPath(const std::string& path) {
  auto ext_pos = path.rfind('.');
  if (ext_pos == std::string::npos) return "application/octet-stream";
  const std::string ext = path.substr(ext_pos);
  if (ext == ".html" || ext == ".htm") return "text/html";
  if (ext == ".js" || ext == ".mjs")   return "application/javascript";
  if (ext == ".css")   return "text/css";
  if (ext == ".json")  return "application/json";
  if (ext == ".png")   return "image/png";
  if (ext == ".jpg" || ext == ".jpeg") return "image/jpeg";
  if (ext == ".svg")   return "image/svg+xml";
  if (ext == ".ico")   return "image/x-icon";
  if (ext == ".woff")  return "font/woff";
  if (ext == ".woff2") return "font/woff2";
  if (ext == ".ttf")   return "font/ttf";
  return "application/octet-stream";
}

// Returns true if |path| contains any path-traversal component.
bool HasPathTraversal(const std::string& path) {
  size_t i = 0;
  while (i <= path.size()) {
    const size_t end = path.find_first_of("/\\", i);
    const size_t seg_end = (end == std::string::npos) ? path.size() : end;
    const std::string seg = path.substr(i, seg_end - i);
    if (seg == ".." || seg == ".") return true;
    if (end == std::string::npos) break;
    i = end + 1;
  }
  return false;
}

// Resolves openclam://ui/<path> → absolute path inside Resources/frontend/.
// Returns empty string if the path is invalid or the file doesn't exist.
std::string ResolveUiPath(const std::string& url_path) {
  // url_path is like "/sessions/index.html" — strip leading '/'.
  std::string rel = url_path;
  if (!rel.empty() && rel[0] == '/') rel = rel.substr(1);
  if (rel.empty() || HasPathTraversal(rel)) return {};

#if defined(OS_MAC)
  NSBundle* bundle = [NSBundle mainBundle];
  NSString* resources_dir = [bundle resourcePath];
  if (!resources_dir) return {};

  NSString* frontend_dir =
      [resources_dir stringByAppendingPathComponent:@"frontend"];
  NSString* full_path = [frontend_dir
      stringByAppendingPathComponent:
          [NSString stringWithUTF8String:rel.c_str()]];

  // Canonicalize both paths and verify the file stays inside frontend/.
  NSString* canon_full = [full_path stringByStandardizingPath];
  NSString* canon_root = [frontend_dir stringByStandardizingPath];
  if (![canon_full hasPrefix:canon_root]) return {};

  // Only serve files that actually exist (not directories).
  BOOL is_dir = NO;
  NSFileManager* fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:canon_full isDirectory:&is_dir] || is_dir)
    return {};

  return [canon_full UTF8String];
#else
  return {};
#endif
}

// ---------------------------------------------------------------------------
// Scheme handler factory — creates a resource handler per request.
// Uses CefStreamResourceHandler (built-in CEF helper) which handles all the
// response bookkeeping correctly, including MIME type, status code, and
// incremental data delivery.
// ---------------------------------------------------------------------------

class OpenclamSchemeHandlerFactory : public CefSchemeHandlerFactory {
 public:
  OpenclamSchemeHandlerFactory() = default;

  OpenclamSchemeHandlerFactory(const OpenclamSchemeHandlerFactory&) = delete;
  OpenclamSchemeHandlerFactory& operator=(
      const OpenclamSchemeHandlerFactory&) = delete;

  // Called on the IO thread.
  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> /*browser*/,
                                       CefRefPtr<CefFrame> /*frame*/,
                                       const CefString& /*scheme_name*/,
                                       CefRefPtr<CefRequest> request) override {
    CefURLParts parts;
    if (!CefParseURL(request->GetURL(), parts)) return nullptr;

    const std::string host = CefString(&parts.host).ToString();
    const std::string path = CefString(&parts.path).ToString();

    if (host == "ui") {
      const std::string file_path = ResolveUiPath(path);
      if (file_path.empty()) return nullptr;

      CefRefPtr<CefStreamReader> reader =
          CefStreamReader::CreateForFile(file_path);
      if (!reader) return nullptr;

      return new CefStreamResourceHandler(MimeTypeForPath(file_path), reader);
    }

    // Unknown host → let CEF show a network error.
    return nullptr;
  }

 private:
  IMPLEMENT_REFCOUNTING(OpenclamSchemeHandlerFactory);
};

}  // namespace

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void RegisterSchemeHandlerFactory() {
  CefRegisterSchemeHandlerFactory(kSchemeName, "",
                                  new OpenclamSchemeHandlerFactory());
}

}  // namespace client::openclam_scheme
