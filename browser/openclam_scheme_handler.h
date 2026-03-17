// Copyright (c) 2025 OpenClam Authors. All rights reserved.

#ifndef OPENCLAM_BROWSER_OPENCLAM_SCHEME_HANDLER_H_
#define OPENCLAM_BROWSER_OPENCLAM_SCHEME_HANDLER_H_
#pragma once

#include <string>

#include "include/cef_scheme.h"

namespace client::openclam_scheme {

// The custom scheme name.
extern const char kSchemeName[];

// URL origins served by this handler:
//   openclam://ui/<app>/<path>   — static files from the app bundle Resources
//                                  directory under frontend/<app>/
//                                  e.g. openclam://ui/sessions/index.html
//   openclam://agent/<id>        — future: in-memory agent-generated content

// Called from OnContextInitialized (BROWSER process only).
// Installs the scheme handler factory so requests are served.
// Scheme name registration happens in ClientApp::RegisterCustomSchemes
// (common/client_app_delegates_common.cc) so it runs in all processes.
void RegisterSchemeHandlerFactory();

}  // namespace client::openclam_scheme

#endif  // OPENCLAM_BROWSER_OPENCLAM_SCHEME_HANDLER_H_
