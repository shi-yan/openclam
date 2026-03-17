// Copyright (c) 2012 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that
// can be found in the LICENSE file.

#include "tests/cefclient/common/scheme_test_common.h"
#include "tests/shared/common/client_app.h"

namespace client {

// static
void ClientApp::RegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) {
  scheme_test::RegisterCustomSchemes(registrar);
  // Register the openclam:// scheme in all processes (browser + renderers).
  // The actual handler factory is installed only in the browser process via
  // RegisterSchemeHandlerFactory() called from OnContextInitialized.
  registrar->AddCustomScheme(
      "openclam",
      CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
          CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED);
}

}  // namespace client
