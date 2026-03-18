#include "agent/session_store.h"

#include <sqlite3.h>
#include <sys/stat.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

namespace {

// Create all intermediate directories for a file path (like mkdir -p for the
// parent directory).
void mkdirs_for_file(const std::string& file_path) {
  // Walk backwards to find the last '/'
  auto pos = file_path.rfind('/');
  if (pos == std::string::npos) return;
  std::string dir = file_path.substr(0, pos);

  // Walk forward and create each component
  for (std::size_t i = 1; i <= dir.size(); ++i) {
    if (i == dir.size() || dir[i] == '/') {
      std::string sub = dir.substr(0, i + (i == dir.size() ? 0 : 0));
      // Trim trailing slash duplicates
      while (sub.size() > 1 && sub.back() == '/') sub.pop_back();
      ::mkdir(sub.c_str(), 0755);  // ignore errors; final check is on open()
    }
  }
}

// Expand a leading "~/" to the home directory.
std::string expand_home(std::string path) {
  if (!path.empty() && path[0] == '~') {
    const char* home = ::getenv("HOME");
    if (home) path = std::string(home) + path.substr(1);
  }
  return path;
}

}  // namespace

// ---------------------------------------------------------------------------
// SessionStore
// ---------------------------------------------------------------------------

SessionStore::SessionStore(std::string db_path)
    : db_path_(expand_home(std::move(db_path))) {}

SessionStore::~SessionStore() {
  if (db_) {
    sqlite3_close(db_);
    db_ = nullptr;
  }
}

bool SessionStore::open() {
  mkdirs_for_file(db_path_);

  int rc = sqlite3_open_v2(
      db_path_.c_str(), &db_,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nullptr);

  if (rc != SQLITE_OK) {
    std::fprintf(stderr, "[SessionStore] sqlite3_open failed (%s): %s\n",
                 db_path_.c_str(), sqlite3_errmsg(db_));
    db_ = nullptr;
    return false;
  }

  // Busy timeout: wait up to 5 s before returning SQLITE_BUSY.
  sqlite3_busy_timeout(db_, 5000);

  try {
    exec("PRAGMA journal_mode=WAL");
    exec("PRAGMA synchronous=NORMAL");  // safe with WAL; faster than FULL
    apply_migrations();
  } catch (const std::exception& e) {
    std::fprintf(stderr, "[SessionStore] init error: %s\n", e.what());
    sqlite3_close(db_);
    db_ = nullptr;
    return false;
  }

  return true;
}

// ---------------------------------------------------------------------------
// Schema migrations
//
// Add new migrations at the END of the list.  Each migration is run exactly
// once; the schema_version PRAGMA tracks which have been applied.
// ---------------------------------------------------------------------------

void SessionStore::apply_migrations() {
  // Read current user_version (our schema version counter)
  int version = 0;
  {
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "PRAGMA user_version", -1, &stmt, nullptr);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
      version = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
  }

  // Migration 1 — initial schema
  if (version < 1) {
    exec(R"sql(
      CREATE TABLE IF NOT EXISTS session_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    )sql");

    exec(R"sql(
      CREATE TABLE IF NOT EXISTS tabs (
        tab_id      TEXT PRIMARY KEY,
        current_url TEXT NOT NULL DEFAULT '',
        title       TEXT NOT NULL DEFAULT '',
        tab_index   INTEGER NOT NULL
      )
    )sql");

    exec(R"sql(
      CREATE TABLE IF NOT EXISTS context (
        seq        INTEGER PRIMARY KEY AUTOINCREMENT,
        role       TEXT    NOT NULL,
        content    TEXT    NOT NULL,
        token_est  INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    )sql");

    exec(R"sql(
      CREATE TABLE IF NOT EXISTS chat_history (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        role        TEXT    NOT NULL,
        text        TEXT    NOT NULL,
        media_path  TEXT,
        is_thinking INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL
      )
    )sql");

    exec(R"sql(
      CREATE TABLE IF NOT EXISTS screenshots (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        req_id      TEXT    NOT NULL,
        file_path   TEXT    NOT NULL,
        width       INTEGER,
        height      INTEGER,
        created_at  INTEGER NOT NULL
      )
    )sql");

    exec("PRAGMA user_version = 1");
    version = 1;
  }

  // Migration 2 — pending_tool_calls table for crash recovery
  if (version < 2) {
    exec(R"sql(
      CREATE TABLE IF NOT EXISTS pending_tool_calls (
        tool_use_id   TEXT PRIMARY KEY,
        request_id    TEXT NOT NULL,
        tool_name     TEXT NOT NULL,
        args_json     TEXT NOT NULL DEFAULT '{}',
        dispatched_at INTEGER NOT NULL
      )
    )sql");

    exec("PRAGMA user_version = 2");
    version = 2;
  }

  // Future migrations go here:
  // if (version < 3) { ... exec("PRAGMA user_version = 3"); version = 3; }
}

// ---------------------------------------------------------------------------
// Session metadata
// ---------------------------------------------------------------------------

void SessionStore::set_meta(const std::string& key,
                             const std::string& value) {
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_,
      "INSERT OR REPLACE INTO session_meta (key, value) VALUES (?, ?)",
      -1, &stmt, nullptr);

  if (rc != SQLITE_OK) {
    std::fprintf(stderr, "[SessionStore] set_meta prepare failed: %s\n",
                 sqlite3_errmsg(db_));
    return;
  }

  sqlite3_bind_text(stmt, 1, key.c_str(),   -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, value.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

std::string SessionStore::get_meta(const std::string& key,
                                    const std::string& default_val) const {
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_,
      "SELECT value FROM session_meta WHERE key = ?",
      -1, &stmt, nullptr);

  if (rc != SQLITE_OK) return default_val;

  sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);

  std::string result = default_val;
  if (sqlite3_step(stmt) == SQLITE_ROW) {
    const char* val =
        reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
    if (val) result = val;
  }
  sqlite3_finalize(stmt);
  return result;
}

// ---------------------------------------------------------------------------
// Tab persistence
// ---------------------------------------------------------------------------

void SessionStore::upsert_tab(const std::string& tab_id,
                               const std::string& url,
                               const std::string& title,
                               int                tab_index) {
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_,
      "INSERT OR REPLACE INTO tabs (tab_id, current_url, title, tab_index)"
      " VALUES (?, ?, ?, ?)",
      -1, &stmt, nullptr);

  if (rc != SQLITE_OK) {
    std::fprintf(stderr, "[SessionStore] upsert_tab prepare failed: %s\n",
                 sqlite3_errmsg(db_));
    return;
  }

  sqlite3_bind_text(stmt, 1, tab_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, url.c_str(),    -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 3, title.c_str(),  -1, SQLITE_TRANSIENT);
  sqlite3_bind_int (stmt, 4, tab_index);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

void SessionStore::delete_tab(const std::string& tab_id) {
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_, "DELETE FROM tabs WHERE tab_id = ?", -1, &stmt, nullptr);
  if (rc != SQLITE_OK) return;

  sqlite3_bind_text(stmt, 1, tab_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

std::vector<Tab> SessionStore::load_tabs() const {
  std::vector<Tab> tabs;

  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_,
      "SELECT tab_id, current_url, title, tab_index"
      " FROM tabs ORDER BY tab_index ASC",
      -1, &stmt, nullptr);

  if (rc != SQLITE_OK) return tabs;

  while (sqlite3_step(stmt) == SQLITE_ROW) {
    Tab t;
    auto col_str = [&](int i) -> std::string {
      const char* s =
          reinterpret_cast<const char*>(sqlite3_column_text(stmt, i));
      return s ? s : "";
    };
    t.tab_id      = col_str(0);
    t.current_url = col_str(1);
    t.title       = col_str(2);
    t.tab_index   = sqlite3_column_int(stmt, 3);
    tabs.push_back(std::move(t));
  }
  sqlite3_finalize(stmt);
  return tabs;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------
// Pending tool call tracking
// ---------------------------------------------------------------------------

void SessionStore::insert_pending_tool_call(const std::string& tool_use_id,
                                             const std::string& request_id,
                                             const std::string& tool_name,
                                             const std::string& args_json) {
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_,
      "INSERT OR REPLACE INTO pending_tool_calls"
      " (tool_use_id, request_id, tool_name, args_json, dispatched_at)"
      " VALUES (?, ?, ?, ?, ?)",
      -1, &stmt, nullptr);

  if (rc != SQLITE_OK) {
    std::fprintf(stderr, "[SessionStore] insert_pending_tool_call failed: %s\n",
                 sqlite3_errmsg(db_));
    return;
  }

  int64_t now = static_cast<int64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::system_clock::now().time_since_epoch()).count());

  sqlite3_bind_text(stmt, 1, tool_use_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, request_id.c_str(),  -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 3, tool_name.c_str(),   -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 4, args_json.c_str(),   -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 5, now);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

void SessionStore::delete_pending_tool_call(const std::string& tool_use_id) {
  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_,
      "DELETE FROM pending_tool_calls WHERE tool_use_id = ?",
      -1, &stmt, nullptr);
  if (rc != SQLITE_OK) return;

  sqlite3_bind_text(stmt, 1, tool_use_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_step(stmt);
  sqlite3_finalize(stmt);
}

std::vector<SessionStore::PendingToolCall>
SessionStore::load_pending_tool_calls() const {
  std::vector<PendingToolCall> result;

  sqlite3_stmt* stmt = nullptr;
  int rc = sqlite3_prepare_v2(
      db_,
      "SELECT tool_use_id, request_id, tool_name, args_json, dispatched_at"
      " FROM pending_tool_calls ORDER BY dispatched_at ASC",
      -1, &stmt, nullptr);
  if (rc != SQLITE_OK) return result;

  while (sqlite3_step(stmt) == SQLITE_ROW) {
    PendingToolCall p;
    auto col_str = [&](int i) -> std::string {
      const char* s =
          reinterpret_cast<const char*>(sqlite3_column_text(stmt, i));
      return s ? s : "";
    };
    p.tool_use_id   = col_str(0);
    p.request_id    = col_str(1);
    p.tool_name     = col_str(2);
    p.args_json     = col_str(3);
    p.dispatched_at = sqlite3_column_int64(stmt, 4);
    result.push_back(std::move(p));
  }
  sqlite3_finalize(stmt);
  return result;
}

// ---------------------------------------------------------------------------

void SessionStore::exec(const std::string& sql) const {
  char* errmsg = nullptr;
  int rc = sqlite3_exec(db_, sql.c_str(), nullptr, nullptr, &errmsg);
  if (rc != SQLITE_OK) {
    std::string msg = errmsg ? errmsg : "(unknown)";
    sqlite3_free(errmsg);
    throw std::runtime_error("[SessionStore] SQL error: " + msg +
                             "\nSQL: " + sql);
  }
}
