# OpenClam — Agent-First Web Browser

## What This Project Is

OpenClam is an **agent-first web browser** built on top of the [Chromium Embedded Framework (CEF)](https://bitbucket.org/chromiumembedded/cef). The codebase is derived from CEF's official example browser (`tests/cefclient`) and extended to support AI agent control.

The core idea: an AI agent drives the browser to accomplish tasks autonomously, rather than a human operating it directly.

## How the Agent Controls the Browser

The agent has three primary mechanisms for interacting with web pages:

1. **Predefined function calls** — a set of structured browser actions (navigation, clicking, form filling, etc.) exposed as callable tools for the agent.
2. **Ad hoc JavaScript injection** — the agent can write and execute arbitrary JS scripts against the current page via CEF's `ExecuteJavaScript` API to manipulate the DOM or extract information.
3. **CEF input event injection** — the agent can synthesize mouse and keyboard events through CEF's `SendMouseClickEvent`, `SendKeyEvent`, etc., to interact with pages that don't respond well to JS manipulation.

## Why CEF (Not Chrome Extension or DevTools API)

Before settling on CEF, two alternatives were investigated:

- **Chrome Extension** — rejected due to restrictive permissions model; extensions cannot freely inject events or access all page internals without user-facing permission prompts.
- **Chrome DevTools Protocol (CDP)** — rejected because it also has permission and access restrictions that limit what an agent can do programmatically.

CEF was chosen because it runs Chromium as an embedded library with full programmatic control and no permission restrictions — the agent has the same access as the browser process itself.

## Codebase Structure

The project mirrors the `tests/cefclient` layout from the CEF distribution:

```
browser/       # Browser process code (UI, window management, client handlers)
common/        # Code shared between browser and renderer processes
renderer/      # Renderer process code
resources/     # HTML/CSS/JS resources bundled with the app
mac/           # macOS-specific resources (Info.plist, icons, xibs)
```

Shared utility code (message loops, resource loading, app scaffolding) is pulled directly from `${CEF_ROOT}/tests/shared/` in the CEF binary distribution — see `CMakeLists.txt` for the exact paths.

## Build Setup

The project builds standalone (not inside the CEF source tree). `CMakeLists.txt` sets `CEF_ROOT` to the local CEF binary distribution and references shared CEF sources via absolute `${CEF_ROOT}/tests/shared/` paths.

```sh
cd build
cmake ..
make -j$(nproc)
```

### Current platform focus
This project is being developed and tested on Mac only. It is ok to break other platform for now. The current priority is to get Mac version work first.

The platform priority is Mac > Linux > Windows