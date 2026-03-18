#pragma once

#include <string>
#include <vector>
#include <cstdint>

#include "agent/types.h"

// Forward-declare the opaque sqlite3 handle so callers do not need sqlite3.h.
struct sqlite3;

// ---------------------------------------------------------------------------
// SessionStore
//
// Wraps a single SQLite database file for one session.
// One read-write connection is used; WAL mode allows a concurrent read-only
// connection from the main thread without blocking writes.
//
// All methods must be called from the session's worker thread EXCEPT:
//   - The constructor/destructor (called on the main thread at session
//     create/destroy time, before the worker is started / after it joins).
//   - load_tabs() / get_meta() may be called from the main thread for display
//     purposes using a separate read-only connection (not yet implemented;
//     for now they are worker-thread only).
// ---------------------------------------------------------------------------
class SessionStore {
 public:
  // db_path: absolute path to the .db file, e.g.
  //   ~/.openclam/sessions/<session_id>/session.db
  explicit SessionStore(std::string db_path);
  ~SessionStore();

  SessionStore(const SessionStore&) = delete;
  SessionStore& operator=(const SessionStore&) = delete;

  // Open or create the database file, enable WAL mode, and apply schema
  // migrations.  Must be called before any other method.
  // Returns false and logs an error on failure.
  bool open();

  // ----- Session metadata (key/value) -----

  void        set_meta(const std::string& key, const std::string& value);
  std::string get_meta(const std::string& key,
                       const std::string& default_val = "") const;

  // ----- Tab persistence -----

  // Insert or replace a tab record.
  void upsert_tab(const std::string& tab_id,
                  const std::string& url,
                  const std::string& title,
                  int                tab_index);

  void delete_tab(const std::string& tab_id);

  // Load all tabs ordered by tab_index.
  std::vector<Tab> load_tabs() const;

  // ----- In-flight tool call tracking (crash recovery) -----
  //
  // A row is inserted when the worker dispatches a tool call and deleted when
  // the ToolResult arrives.  Any rows present at startup indicate calls that
  // were in-flight when the app was killed; SessionManager injects synthetic
  // failure tool_results for them before resuming the session.

  struct PendingToolCall {
    std::string tool_use_id;    // Claude's tool_use block id (from API response)
    std::string request_id;     // our BrowserActionRequest UUID
    std::string tool_name;
    std::string args_json;
    int64_t     dispatched_at;  // unix ms
  };

  void insert_pending_tool_call(const std::string& tool_use_id,
                                const std::string& request_id,
                                const std::string& tool_name,
                                const std::string& args_json);

  void delete_pending_tool_call(const std::string& tool_use_id);

  // Returns all rows — non-empty at startup means the session was interrupted.
  std::vector<PendingToolCall> load_pending_tool_calls() const;

 private:
  std::string db_path_;
  sqlite3*    db_ = nullptr;

  // Run all pending schema migrations in order.
  void apply_migrations();

  // Execute a SQL statement with no parameters; aborts on error (for migrations).
  void exec(const std::string& sql) const;

  // Like exec() but returns false on error instead of aborting.
  bool exec_nothrow(const std::string& sql) const;
};
