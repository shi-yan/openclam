#pragma once

#include <string>
#include <cstdint>

// ---------------------------------------------------------------------------
// SessionStatus
// ---------------------------------------------------------------------------

enum class SessionStatus {
  Created,
  Running,
  WaitingForTool,   // blocked waiting for a BrowserActionResult
  WaitingForUser,   // agent explicitly asked for user input
  Completed,
  Failed,
  Cancelled,
};

inline std::string to_string(SessionStatus s) {
  switch (s) {
    case SessionStatus::Created:        return "created";
    case SessionStatus::Running:        return "running";
    case SessionStatus::WaitingForTool: return "waiting_for_tool";
    case SessionStatus::WaitingForUser: return "waiting_for_user";
    case SessionStatus::Completed:      return "completed";
    case SessionStatus::Failed:         return "failed";
    case SessionStatus::Cancelled:      return "cancelled";
  }
  return "unknown";
}

inline SessionStatus session_status_from_string(const std::string& s) {
  if (s == "running")          return SessionStatus::Running;
  if (s == "waiting_for_tool") return SessionStatus::WaitingForTool;
  if (s == "waiting_for_user") return SessionStatus::WaitingForUser;
  if (s == "completed")        return SessionStatus::Completed;
  if (s == "failed")           return SessionStatus::Failed;
  if (s == "cancelled")        return SessionStatus::Cancelled;
  return SessionStatus::Created;
}

inline bool is_terminal(SessionStatus s) {
  return s == SessionStatus::Completed ||
         s == SessionStatus::Failed    ||
         s == SessionStatus::Cancelled;
}

// ---------------------------------------------------------------------------
// TriggerType
// ---------------------------------------------------------------------------

enum class TriggerType {
  UserPrompt,
  Cron,
};

inline std::string to_string(TriggerType t) {
  return t == TriggerType::Cron ? "cron" : "user_prompt";
}

inline TriggerType trigger_type_from_string(const std::string& s) {
  return s == "cron" ? TriggerType::Cron : TriggerType::UserPrompt;
}

// ---------------------------------------------------------------------------
// Tab
//
// Lightweight record owned by Session::tabs.  All fields are readable from
// any thread.  The actual BrowserTabMac pointer will be added in Phase 3
// once BrowserTabMac is extracted to its own header.
// ---------------------------------------------------------------------------

struct Tab {
  std::string tab_id;       // e.g. "a1b2c3d4-t0"
  std::string current_url;
  std::string title;
  int         tab_index;    // position in Session::tabs
};
