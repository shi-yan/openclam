# Standalone CMakeLists.txt for cefclient.
#
# Builds cefclient independently from the CEF binary distribution's parent
# CMakeLists.txt, so the project can be moved to any location and pointed at
# different CEF versions without changing anything except CEF_ROOT.
#
# USAGE
# -----
# From the cefclient directory:
#
#   mkdir build && cd build
#
#   # Xcode (arm64 Mac):
#   cmake -G "Xcode" -DPROJECT_ARCH="arm64" \
#         -DCEF_ROOT="/path/to/cef_binary_..." \
#         -f ../CMakeLists_standalone.txt ..
#
#   # Ninja (arm64 Mac):
#   cmake -G "Ninja" -DPROJECT_ARCH="arm64" -DCMAKE_BUILD_TYPE=Debug \
#         -DCEF_ROOT="/path/to/cef_binary_..." \
#         -f ../CMakeLists_standalone.txt ..
#   ninja cefclient
#
# If CEF_ROOT is not specified it defaults to the grandparent directory of this
# file, which matches the layout inside the official binary distribution
# (tests/cefclient/ is two levels below the distribution root).

set(CEF_ROOT /Users/shiy/work/cef_binary_145.0.28+g51162e8+chromium-145.0.7632.160_macosarm64)

cmake_minimum_required(VERSION 3.21)
project(cefclient_standalone)

set(CMAKE_CONFIGURATION_TYPES Debug Release)
set_property(GLOBAL PROPERTY USE_FOLDERS ON)

# ---------------------------------------------------------------------------
# CEF_ROOT – path to the CEF binary distribution.
# Override with:  cmake -DCEF_ROOT=/absolute/path/to/cef_binary_...
# ---------------------------------------------------------------------------
if(NOT DEFINED CEF_ROOT)
  # Default: two directories above this CMakeLists_standalone.txt
  # (tests/cefclient → tests → cef_binary_root)
  get_filename_component(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
  message(STATUS "CEF_ROOT not specified, defaulting to: ${CEF_ROOT}")
endif()

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")

# ---------------------------------------------------------------------------
# External dependencies
# ---------------------------------------------------------------------------
include(FetchContent)

# moodycamel/concurrentqueue — lock-free MPMC / blocking queue (header-only)
FetchContent_Declare(
  concurrentqueue
  URL https://github.com/cameron314/concurrentqueue/archive/refs/tags/v1.0.4.tar.gz
)
FetchContent_GetProperties(concurrentqueue)
if(NOT concurrentqueue_POPULATED)
  FetchContent_Populate(concurrentqueue)
endif()

# nlohmann/json — header-only JSON library
FetchContent_Declare(
  nlohmann_json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
)
FetchContent_MakeAvailable(nlohmann_json)

# cpp-httplib — header-only HTTP/HTTPS client (requires OpenSSL for SSL support)
FetchContent_Declare(
  httplib
  URL https://github.com/yhirose/cpp-httplib/archive/refs/tags/v0.18.3.tar.gz
)
FetchContent_MakeAvailable(httplib)

# OpenSSL — needed by cpp-httplib for HTTPS
find_package(OpenSSL REQUIRED)

# Load the CEF configuration (sets OS_MAC/OS_LINUX/OS_WINDOWS, compiler flags,
# CEF_LIBCEF_DLL_WRAPPER_PATH, CEF_HELPER_APP_SUFFIXES, CEF_STANDARD_LIBS,
# CEF_BINARY_FILES, CEF_RESOURCE_FILES, etc.)
find_package(CEF REQUIRED)

# Remove -Werror from the CEF compiler flags so warnings do not abort the build.
# CEF sets this in cef_variables.cmake; it also sets the Xcode attribute
# GCC_TREAT_WARNINGS_AS_ERRORS inside SET_COMMON_TARGET_PROPERTIES — that is
# overridden per-target below after SET_EXECUTABLE_TARGET_PROPERTIES is called.
list(REMOVE_ITEM CEF_COMPILER_FLAGS -Werror)

# Build the libcef_dll_wrapper static library.
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

PRINT_CEF_CONFIG()


# ===========================================================================
# Source file lists (identical to the original CMakeLists.txt)
# ===========================================================================

# cefclient browser sources.
set(CEFCLIENT_BROWSER_BROWSER_SRCS
  browser/base_client_handler.cc
  browser/base_client_handler.h
  browser/binary_transfer_test.cc
  browser/binary_transfer_test.h
  browser/binding_test.cc
  browser/binding_test.h
  browser/browser_window.cc
  browser/browser_window.h
  browser/bytes_write_handler.cc
  browser/bytes_write_handler.h
  browser/client_app_delegates_browser.cc
  browser/client_browser.cc
  browser/client_browser.h
  browser/client_handler.cc
  browser/client_handler.h
  browser/client_handler_osr.cc
  browser/client_handler_osr.h
  browser/client_handler_std.cc
  browser/client_handler_std.h
  browser/client_prefs.cc
  browser/client_prefs.h
  browser/client_types.h
  browser/config_test.cc
  browser/config_test.h
  browser/default_client_handler.cc
  browser/default_client_handler.h
  browser/dialog_test.cc
  browser/dialog_test.h
  browser/hang_test.cc
  browser/hang_test.h
  browser/image_cache.cc
  browser/image_cache.h
  browser/main_context.cc
  browser/main_context.h
  browser/main_context_impl.cc
  browser/main_context_impl.h
  browser/openclam_scheme_handler.mm
  browser/openclam_scheme_handler.h
  browser/media_router_test.cc
  browser/media_router_test.h
  browser/osr_dragdrop_events.h
  browser/osr_renderer.cc
  browser/osr_renderer.h
  browser/osr_renderer_settings.h
  browser/preferences_test.cc
  browser/preferences_test.h
  browser/resource.h
  browser/response_filter_test.cc
  browser/response_filter_test.h
  browser/root_window.cc
  browser/root_window.h
  browser/root_window_create.cc
  browser/root_window_manager.cc
  browser/root_window_manager.h
  browser/root_window_views.cc
  browser/root_window_views.h
  browser/scheme_test.cc
  browser/scheme_test.h
  browser/server_test.cc
  browser/server_test.h
  browser/task_manager_test.cc
  browser/task_manager_test.h
  browser/temp_window.h
  browser/test_runner.cc
  browser/test_runner.h
  browser/urlrequest_test.cc
  browser/urlrequest_test.h
  browser/views_menu_bar.cc
  browser/views_menu_bar.h
  browser/views_overlay_browser.cc
  browser/views_overlay_browser.h
  browser/views_overlay_controls.cc
  browser/views_overlay_controls.h
  browser/views_style.cc
  browser/views_style.h
  browser/views_window.cc
  browser/views_window.h
  browser/window_test.cc
  browser/window_test.h
  browser/window_test_runner.cc
  browser/window_test_runner.h
  browser/window_test_runner_views.cc
  browser/window_test_runner_views.h
  )
source_group(cefclient\\\\browser FILES ${CEFCLIENT_BROWSER_BROWSER_SRCS})

# Agent subsystem sources (platform-independent C++17)
set(CEFCLIENT_AGENT_SRCS
  agent/agent_loop.cc
  agent/agent_loop.h
  agent/browser_action_dispatcher.h
  agent/id_utils.h
  agent/llm_client.h
  agent/anthropic_client.cc
  agent/anthropic_client.h
  agent/openai_client.cc
  agent/openai_client.h
  agent/gemini_client.cc
  agent/gemini_client.h
  agent/llm_factory.cc
  agent/messages.h
  agent/session.cc
  agent/session.h
  agent/session_manager.cc
  agent/session_manager.h
  agent/session_store.cc
  agent/session_store.h
  agent/types.h
  )
source_group(cefclient\\\\agent FILES ${CEFCLIENT_AGENT_SRCS})

# macOS-only agent sources (need ObjC / AppKit / CoreGraphics)
set(CEFCLIENT_AGENT_MAC_SRCS
  agent/browser_action_dispatcher.mm
  )

set(CEFCLIENT_BROWSER_SHARED_BROWSER_SRCS
  shared/browser/client_app_browser.cc
  shared/browser/client_app_browser.h
  shared/browser/file_util.cc
  shared/browser/file_util.h
  shared/browser/geometry_util.cc
  shared/browser/geometry_util.h
  shared/browser/main_message_loop.cc
  shared/browser/main_message_loop.h
  shared/browser/main_message_loop_external_pump.cc
  shared/browser/main_message_loop_external_pump.h
  shared/browser/main_message_loop_std.cc
  shared/browser/main_message_loop_std.h
  shared/browser/resource_util.h
  )
source_group(shared\\\\browser FILES ${CEFCLIENT_BROWSER_SHARED_BROWSER_SRCS})

set(CEFCLIENT_BROWSER_SRCS
  ${CEFCLIENT_BROWSER_BROWSER_SRCS}
  ${CEFCLIENT_BROWSER_SHARED_BROWSER_SRCS}
  )

# cefclient common sources.
set(CEFCLIENT_COMMON_COMMON_SRCS
  common/client_app_delegates_common.cc
  common/scheme_test_common.cc
  common/scheme_test_common.h
  )
source_group(cefclient\\\\common FILES ${CEFCLIENT_COMMON_COMMON_SRCS})

set(CEFCLIENT_COMMON_SHARED_COMMON_SRCS
  shared/common/binary_value_utils.cc
  shared/common/binary_value_utils.h
  shared/common/client_app.cc
  shared/common/client_app.h
  shared/common/client_app_other.cc
  shared/common/client_app_other.h
  shared/common/client_switches.cc
  shared/common/client_switches.h
  shared/common/string_util.cc
  shared/common/string_util.h
  )
source_group(shared\\\\common FILES ${CEFCLIENT_COMMON_SHARED_COMMON_SRCS})

set(CEFCLIENT_COMMON_SRCS
  ${CEFCLIENT_COMMON_COMMON_SRCS}
  ${CEFCLIENT_COMMON_SHARED_COMMON_SRCS}
  )

# cefclient renderer sources.
set(CEFCLIENT_RENDERER_RENDERER_SRCS
  renderer/client_app_delegates_renderer.cc
  renderer/client_renderer.cc
  renderer/client_renderer.h
  renderer/ipc_performance_test.cc
  renderer/ipc_performance_test.h
  renderer/performance_test.cc
  renderer/performance_test.h
  renderer/performance_test_setup.h
  renderer/performance_test_tests.cc
  )
source_group(cefclient\\\\renderer FILES ${CEFCLIENT_RENDERER_RENDERER_SRCS})

set(CEFCLIENT_RENDERER_SHARED_RENDERER_SRCS
  shared/renderer/client_app_renderer.cc
  shared/renderer/client_app_renderer.h
  )
source_group(shared\\\\renderer FILES ${CEFCLIENT_RENDERER_SHARED_RENDERER_SRCS})

set(CEFCLIENT_RENDERER_SRCS
  ${CEFCLIENT_RENDERER_RENDERER_SRCS}
  ${CEFCLIENT_RENDERER_SHARED_RENDERER_SRCS}
  )

# Linux sources.
set(CEFCLIENT_LINUX_SRCS
  cefclient_gtk.cc
  )
source_group(cefclient FILES ${CEFCLIENT_LINUX_SRCS})

set(CEFCLIENT_LINUX_BROWSER_SRCS
  browser/browser_window_osr_gtk.cc
  browser/browser_window_osr_gtk.h
  browser/browser_window_std_gtk.cc
  browser/browser_window_std_gtk.h
  browser/dialog_handler_gtk.cc
  browser/dialog_handler_gtk.h
  browser/main_context_impl_posix.cc
  browser/main_message_loop_multithreaded_gtk.cc
  browser/main_message_loop_multithreaded_gtk.h
  browser/print_handler_gtk.cc
  browser/print_handler_gtk.h
  browser/resource_util_linux.cc
  browser/root_window_gtk.cc
  browser/root_window_gtk.h
  browser/temp_window_x11.cc
  browser/temp_window_x11.h
  browser/util_gtk.cc
  browser/util_gtk.h
  browser/window_test_runner_gtk.cc
  browser/window_test_runner_gtk.h
  )
source_group(cefclient\\\\browser FILES ${CEFCLIENT_LINUX_BROWSER_SRCS})

set(CEFCLIENT_LINUX_SHARED_BROWSER_SRCS
  ${CEF_ROOT}/tests/shared/browser/main_message_loop_external_pump_linux.cc
  ${CEF_ROOT}/tests/shared/browser/resource_util_posix.cc
  )
source_group(shared\\\\browser FILES ${CEFCLIENT_LINUX_SHARED_BROWSER_SRCS})

set(CEFCLIENT_LINUX_SRCS
  ${CEFCLIENT_LINUX_SRCS}
  ${CEFCLIENT_LINUX_BROWSER_SRCS}
  ${CEFCLIENT_LINUX_SHARED_BROWSER_SRCS}
  )

# macOS sources.
set(CEFCLIENT_MACOSX_SRCS
  cefclient_mac.mm
  )
source_group(cefclient FILES ${CEFCLIENT_MACOSX_SRCS})

set(CEFCLIENT_MACOSX_BROWSER_SRCS
  browser/browser_window_osr_mac.h
  browser/browser_window_osr_mac.mm
  browser/browser_window_std_mac.h
  browser/browser_window_std_mac.mm
  browser/main_context_impl_posix.cc
  browser/osr_accessibility_helper.cc
  browser/osr_accessibility_helper.h
  browser/osr_accessibility_node.cc
  browser/osr_accessibility_node.h
  browser/osr_accessibility_node_mac.mm
  browser/root_window_mac.h
  browser/root_window_mac.mm
  browser/temp_window_mac.h
  browser/temp_window_mac.mm
  browser/text_input_client_osr_mac.h
  browser/text_input_client_osr_mac.mm
  browser/util_mac.h
  browser/util_mac.mm
  browser/views_window_mac.mm
  browser/window_test_runner_mac.h
  browser/window_test_runner_mac.mm
  )
source_group(cefclient\\\\browser FILES ${CEFCLIENT_MACOSX_BROWSER_SRCS})

set(CEFCLIENT_MACOSX_SHARED_BROWSER_SRCS
  shared/browser/main_message_loop_external_pump_mac.mm
  shared/browser/resource_util_mac.mm
  shared/browser/resource_util_posix.cc
  )
source_group(shared\\\\browser FILES ${CEFCLIENT_MACOSX_SHARED_BROWSER_SRCS})

set(CEFCLIENT_MAC_SRCS
  ${CEFCLIENT_MACOSX_SRCS}
  ${CEFCLIENT_MACOSX_BROWSER_SRCS}
  ${CEFCLIENT_MACOSX_SHARED_BROWSER_SRCS}
  )

# macOS helper sources.
set(CEFCLIENT_HELPER_SHARED_SRCS
  shared/process_helper_mac.cc
  )
source_group(shared FILES ${CEFCLIENT_HELPER_SHARED_SRCS})

set(CEFCLIENT_MAC_HELPER_SRCS
  ${CEFCLIENT_HELPER_SHARED_SRCS}
  )

# Windows sources.
set(CEFCLIENT_WINDOWS_SRCS
  cefclient_win.cc
  )
source_group(cefclient FILES ${CEFCLIENT_WINDOWS_SRCS})

set(CEFCLIENT_WINDOWS_BROWSER_SRCS
  browser/browser_window_osr_win.cc
  browser/browser_window_osr_win.h
  browser/browser_window_std_win.cc
  browser/browser_window_std_win.h
  browser/main_context_impl_win.cc
  browser/main_message_loop_multithreaded_win.cc
  browser/main_message_loop_multithreaded_win.h
  browser/osr_accessibility_helper.cc
  browser/osr_accessibility_helper.h
  browser/osr_accessibility_node.cc
  browser/osr_accessibility_node.h
  browser/osr_accessibility_node_win.cc
  browser/osr_d3d11_win.cc
  browser/osr_d3d11_win.h
  browser/osr_dragdrop_win.cc
  browser/osr_dragdrop_win.h
  browser/osr_ime_handler_win.cc
  browser/osr_ime_handler_win.h
  browser/osr_render_handler_win.cc
  browser/osr_render_handler_win.h
  browser/osr_render_handler_win_d3d11.cc
  browser/osr_render_handler_win_d3d11.h
  browser/osr_render_handler_win_gl.cc
  browser/osr_render_handler_win_gl.h
  browser/osr_window_win.cc
  browser/osr_window_win.h
  browser/resource_util_win_idmap.cc
  browser/root_window_win.cc
  browser/root_window_win.h
  browser/temp_window_win.cc
  browser/temp_window_win.h
  browser/window_test_runner_win.cc
  browser/window_test_runner_win.h
  )
source_group(cefclient\\\\browser FILES ${CEFCLIENT_WINDOWS_BROWSER_SRCS})

set(CEFCLIENT_WINDOWS_SHARED_BROWSER_SRCS
  ${CEF_ROOT}/tests/shared/browser/main_message_loop_external_pump_win.cc
  ${CEF_ROOT}/tests/shared/browser/resource_util_win.cc
  ${CEF_ROOT}/tests/shared/browser/util_win.cc
  ${CEF_ROOT}/tests/shared/browser/util_win.h
  )
source_group(shared\\\\browser FILES ${CEFCLIENT_WINDOWS_SHARED_BROWSER_SRCS})

set(CEFCLIENT_WINDOWS_WIN_SRCS
  win/cefclient.rc
  )
source_group(cefclient\\\\win FILES ${CEFCLIENT_WINDOWS_WIN_SRCS})

set(CEFCLIENT_WINDOWS_SRCS
  ${CEFCLIENT_WINDOWS_SRCS}
  ${CEFCLIENT_WINDOWS_BROWSER_SRCS}
  ${CEFCLIENT_WINDOWS_SHARED_BROWSER_SRCS}
  ${CEFCLIENT_WINDOWS_WIN_SRCS}
  )

# Resources.
set(CEFCLIENT_RESOURCES_MAC_SRCS_MAC
  mac/Info.plist.in
  mac/cefclient.icns
  )
APPEND_PLATFORM_SOURCES(CEFCLIENT_RESOURCES_MAC_SRCS)
source_group(cefclient\\\\mac FILES ${CEFCLIENT_RESOURCES_MAC_SRCS})

set(CEFCLIENT_RESOURCES_MAC_ENGLISH_LPROJ_SRCS_MAC
  mac/English.lproj/InfoPlist.strings
  mac/English.lproj/MainMenu.xib
  )
APPEND_PLATFORM_SOURCES(CEFCLIENT_RESOURCES_MAC_ENGLISH_LPROJ_SRCS)
source_group(cefclient\\\\mac\\\\English.lproj FILES ${CEFCLIENT_RESOURCES_MAC_ENGLISH_LPROJ_SRCS})

set(CEFCLIENT_RESOURCES_RESOURCES_SRCS
  resources/binary_transfer.html
  resources/binding.html
  resources/config.html
  resources/dialogs.html
  resources/draggable.html
  resources/hang.html
  resources/ipc_performance.html
  resources/localstorage.html
  resources/logo.png
  resources/media_router.html
  resources/menu_icon.1x.png
  resources/menu_icon.2x.png
  resources/other_tests.html
  resources/performance.html
  resources/performance2.html
  resources/pip.html
  resources/preferences.html
  resources/response_filter.html
  resources/server.html
  resources/task_manager.html
  resources/transparency.html
  resources/urlrequest.html
  resources/websocket.html
  resources/window.html
  resources/xmlhttprequest.html
  )
source_group(cefclient\\\\resources FILES ${CEFCLIENT_RESOURCES_RESOURCES_SRCS})

set(CEFCLIENT_RESOURCES_SHARED_RESOURCES_SRCS
  ${CEF_ROOT}/tests/shared/resources/osr_test.html
  ${CEF_ROOT}/tests/shared/resources/pdf.html
  ${CEF_ROOT}/tests/shared/resources/pdf.pdf
  ${CEF_ROOT}/tests/shared/resources/window_icon.1x.png
  ${CEF_ROOT}/tests/shared/resources/window_icon.2x.png
  )
source_group(shared\\\\resources FILES ${CEFCLIENT_RESOURCES_SHARED_RESOURCES_SRCS})

set(CEFCLIENT_RESOURCES_SRCS
  ${CEFCLIENT_RESOURCES_MAC_SRCS}
  ${CEFCLIENT_RESOURCES_MAC_ENGLISH_LPROJ_SRCS}
  ${CEFCLIENT_RESOURCES_RESOURCES_SRCS}
  ${CEFCLIENT_RESOURCES_SHARED_RESOURCES_SRCS}
  )


# ===========================================================================
# Shared configuration
# ===========================================================================

set(CEF_TARGET "cefclient")
if(OS_MAC)
  set(CEF_HELPER_TARGET "cefclient_Helper")
  set(CEF_HELPER_OUTPUT_NAME "cefclient Helper")
else()
  ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")
endif()

SET_CEF_TARGET_OUT_DIR()


# ===========================================================================
# Linux configuration
# ===========================================================================

if(OS_LINUX)
  set(CEFCLIENT_SRCS
    ${CEFCLIENT_BROWSER_SRCS}
    ${CEFCLIENT_COMMON_SRCS}
    ${CEFCLIENT_RENDERER_SRCS}
    ${CEFCLIENT_RESOURCES_SRCS}
    ${CEFCLIENT_LINUX_SRCS}
    )

  FIND_LINUX_LIBRARIES("gmodule-2.0 gtk+-3.0 gthread-2.0 gtk+-unix-print-3.0 xi")

  add_executable(${CEF_TARGET} ${CEFCLIENT_SRCS})
  SET_EXECUTABLE_TARGET_PROPERTIES(${CEF_TARGET})
  add_dependencies(${CEF_TARGET} libcef_dll_wrapper)
  target_link_libraries(${CEF_TARGET} libcef_lib libcef_dll_wrapper "GL" ${CEF_STANDARD_LIBS})

  set_target_properties(${CEF_TARGET} PROPERTIES INSTALL_RPATH "$ORIGIN")
  set_target_properties(${CEF_TARGET} PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE)
  set_target_properties(${CEF_TARGET} PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CEF_TARGET_OUT_DIR})

  add_definitions("-DGTK_DISABLE_DEPRECATED")

  COPY_FILES("${CEF_TARGET}" "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES("${CEF_TARGET}" "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES("${CEF_TARGET}" "${CEFCLIENT_RESOURCES_SRCS}" "${CMAKE_CURRENT_SOURCE_DIR}" "${CEF_TARGET_OUT_DIR}/cefclient_files")

  SET_LINUX_SUID_PERMISSIONS("${CEF_TARGET}" "${CEF_TARGET_OUT_DIR}/chrome-sandbox")
endif()


# ===========================================================================
# macOS configuration
# ===========================================================================

if(OS_MAC)
  option(OPTION_USE_ARC "Build with ARC (automatic Reference Counting) on macOS." ON)
  if(OPTION_USE_ARC)
    list(APPEND CEF_COMPILER_FLAGS
      -fobjc-arc
      )
    set_target_properties(${target} PROPERTIES
      CLANG_ENABLE_OBJC_ARC "YES"
      )
  endif()

  set(CEFCLIENT_SRCS
    ${CEFCLIENT_BROWSER_SRCS}
    ${CEFCLIENT_COMMON_SRCS}
    ${CEFCLIENT_RESOURCES_SRCS}
    ${CEFCLIENT_MAC_SRCS}
    ${CEFCLIENT_AGENT_SRCS}
    ${CEFCLIENT_AGENT_MAC_SRCS}
    )

  set(CEFCLIENT_HELPER_SRCS
    ${CEFCLIENT_COMMON_SRCS}
    ${CEFCLIENT_RENDERER_SRCS}
    ${CEFCLIENT_MAC_HELPER_SRCS}
    )

  set(CEF_APP "${CEF_TARGET_OUT_DIR}/${CEF_TARGET}.app")

  set(EXECUTABLE_NAME "${CEF_TARGET}")
  set(PRODUCT_NAME "${CEF_TARGET}")

  # ---------------------------------------------------------------------------
  # Vue frontend prebuild
  # ---------------------------------------------------------------------------
  find_program(NPM_EXECUTABLE npm REQUIRED)

  add_custom_target(vue_build_sessions
    COMMAND ${NPM_EXECUTABLE} install
    COMMAND ${NPM_EXECUTABLE} run build
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/frontend/sessions"
    COMMENT "Building Vue frontend: sessions"
    VERBATIM
  )

  add_custom_target(vue_build_tabs_chat
    COMMAND ${NPM_EXECUTABLE} install
    COMMAND ${NPM_EXECUTABLE} run build
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/frontend/tabs_chat"
    COMMENT "Building Vue frontend: tabs_chat"
    VERBATIM
  )

  add_executable(${CEF_TARGET} MACOSX_BUNDLE ${CEFCLIENT_RESOURCES_SRCS} ${CEFCLIENT_SRCS})
  SET_EXECUTABLE_TARGET_PROPERTIES(${CEF_TARGET})
  target_include_directories(${CEF_TARGET} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  set_target_properties(${CEF_TARGET} PROPERTIES
    XCODE_ATTRIBUTE_GCC_TREAT_WARNINGS_AS_ERRORS NO
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/mac/Info.plist.in
    )
  add_dependencies(${CEF_TARGET} libcef_dll_wrapper vue_build_sessions vue_build_tabs_chat)
  target_link_libraries(${CEF_TARGET}
    libcef_dll_wrapper
    ${CEF_STANDARD_LIBS}
    "-framework OpenGL"
    "-framework CoreGraphics"
    "-framework ImageIO"
    "-framework Foundation"
    sqlite3
    nlohmann_json::nlohmann_json
    httplib::httplib
    OpenSSL::SSL
    OpenSSL::Crypto
    )
  target_include_directories(${CEF_TARGET} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${concurrentqueue_SOURCE_DIR}"
    )

  COPY_MAC_FRAMEWORK("${CEF_TARGET}" "${CEF_BINARY_DIR}" "${CEF_APP}")

  # Copy Vue dist directories into the app bundle Resources folder.
  add_custom_command(
    TARGET ${CEF_TARGET} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/frontend/sessions/dist"
            "${CEF_APP}/Contents/Resources/frontend/sessions"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${CMAKE_CURRENT_SOURCE_DIR}/frontend/tabs_chat/dist"
            "${CEF_APP}/Contents/Resources/frontend/tabs_chat"
    COMMENT "Copying Vue dist files to app bundle"
    VERBATIM
  )

  foreach(_suffix_list ${CEF_HELPER_APP_SUFFIXES})
    string(REPLACE ":" ";" _suffix_list ${_suffix_list})
    list(GET _suffix_list 0 _name_suffix)
    list(GET _suffix_list 1 _target_suffix)
    list(GET _suffix_list 2 _plist_suffix)

    set(_helper_target "${CEF_HELPER_TARGET}${_target_suffix}")
    set(_helper_output_name "${CEF_HELPER_OUTPUT_NAME}${_name_suffix}")

    set(_helper_info_plist "${CMAKE_CURRENT_BINARY_DIR}/helper-Info${_target_suffix}.plist")
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/mac/helper-Info.plist.in" _plist_contents)
    string(REPLACE "\${EXECUTABLE_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
    string(REPLACE "\${PRODUCT_NAME}" "${_helper_output_name}" _plist_contents ${_plist_contents})
    string(REPLACE "\${BUNDLE_ID_SUFFIX}" "${_plist_suffix}" _plist_contents ${_plist_contents})
    file(WRITE ${_helper_info_plist} ${_plist_contents})

    add_executable(${_helper_target} MACOSX_BUNDLE ${CEFCLIENT_HELPER_SRCS})
    SET_EXECUTABLE_TARGET_PROPERTIES(${_helper_target})
    target_include_directories(${_helper_target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    set_target_properties(${_helper_target} PROPERTIES
      XCODE_ATTRIBUTE_GCC_TREAT_WARNINGS_AS_ERRORS NO
      MACOSX_BUNDLE_INFO_PLIST ${_helper_info_plist}
      OUTPUT_NAME ${_helper_output_name}
      )
    add_dependencies(${_helper_target} libcef_dll_wrapper)
    target_link_libraries(${_helper_target} libcef_dll_wrapper ${CEF_STANDARD_LIBS})

    add_dependencies(${CEF_TARGET} "${_helper_target}")

    add_custom_command(
      TARGET ${CEF_TARGET}
      POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_directory
              "${CEF_TARGET_OUT_DIR}/${_helper_output_name}.app"
              "${CEF_APP}/Contents/Frameworks/${_helper_output_name}.app"
      VERBATIM
      )
  endforeach()

  set(PREFIXES
    "mac/"
    "resources/"
    "${CEF_ROOT}/tests/shared/resources/"
    )
  COPY_MAC_RESOURCES("${CEFCLIENT_RESOURCES_SRCS}" "${PREFIXES}" "${CEF_TARGET}" "${CMAKE_CURRENT_SOURCE_DIR}" "${CEF_APP}")
endif()


# ===========================================================================
# Windows configuration
# ===========================================================================

if(OS_WINDOWS)
  set(CEFCLIENT_SRCS
    ${CEFCLIENT_BROWSER_SRCS}
    ${CEFCLIENT_COMMON_SRCS}
    ${CEFCLIENT_RENDERER_SRCS}
    ${CEFCLIENT_RESOURCES_SRCS}
    ${CEFCLIENT_WINDOWS_SRCS}
    )

  set(ADDITIONAL_DELAYLOAD_FLAGS
    /DELAYLOAD:glu32.dll
    /DELAYLOAD:oleaut32.dll
    /DELAYLOAD:opengl32.dll
    )

  if(USE_SANDBOX)
    list(APPEND CEF_SHARED_LINKER_FLAGS
      ${ADDITIONAL_DELAYLOAD_FLAGS}
    )
    add_library(${CEF_TARGET} SHARED ${CEFCLIENT_SRCS})
    SET_LIBRARY_TARGET_PROPERTIES(${CEF_TARGET})

    COPY_SINGLE_FILE(${CEF_TARGET} ${CEF_BINARY_DIR}/bootstrap.exe ${CEF_TARGET_OUT_DIR}/${CEF_TARGET}.exe)

    if(CMAKE_GENERATOR MATCHES "Visual Studio")
      set_target_properties(${CEF_TARGET} PROPERTIES
        VS_DEBUGGER_COMMAND "$<TARGET_FILE_DIR:${CEF_TARGET}>/${CEF_TARGET}.exe"
      )
    endif()
  else()
    list(APPEND CEF_EXE_LINKER_FLAGS
      ${ADDITIONAL_DELAYLOAD_FLAGS}
    )
    add_executable(${CEF_TARGET} WIN32 ${CEFCLIENT_SRCS})
    SET_EXECUTABLE_TARGET_PROPERTIES(${CEF_TARGET})
    ADD_WINDOWS_MANIFEST("${CMAKE_CURRENT_SOURCE_DIR}/win" "${CEF_TARGET}" "exe")
  endif()

  add_dependencies(${CEF_TARGET} libcef_dll_wrapper)
  target_link_libraries(${CEF_TARGET} libcef_lib libcef_dll_wrapper ${CEF_STANDARD_LIBS} d3d11.lib glu32.lib imm32.lib opengl32.lib)

  if(USE_ATL)
    target_link_libraries(${CEF_TARGET} oleacc.lib)
  endif()

  COPY_FILES("${CEF_TARGET}" "${CEF_BINARY_FILES}" "${CEF_BINARY_DIR}" "${CEF_TARGET_OUT_DIR}")
  COPY_FILES("${CEF_TARGET}" "${CEF_RESOURCE_FILES}" "${CEF_RESOURCE_DIR}" "${CEF_TARGET_OUT_DIR}")

  if(USE_SANDBOX)
    SET_LPAC_ACLS("${CEF_TARGET}")
  endif()
endif()
