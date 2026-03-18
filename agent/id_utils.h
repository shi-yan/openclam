#pragma once

#include <string>
#include <cstdint>
#include <cstdio>

// ---------------------------------------------------------------------------
// ID generation utilities
//
// All functions are header-only and use arc4random_buf() (available on macOS
// and all BSDs) to produce cryptographically random identifiers.
// ---------------------------------------------------------------------------

namespace id_utils {

// Returns 8 random hex characters, e.g. "a1b2c3d4".
// Used as the short session ID component embedded in tab IDs.
inline std::string random_hex8() {
  uint32_t v;
  arc4random_buf(&v, sizeof(v));
  char buf[9];
  std::snprintf(buf, sizeof(buf), "%08x", v);
  return buf;
}

// Returns a new session ID: 16 random hex characters, e.g. "a1b2c3d4e5f60718".
inline std::string new_session_id() {
  uint64_t v;
  arc4random_buf(&v, sizeof(v));
  char buf[17];
  std::snprintf(buf, sizeof(buf), "%016llx", static_cast<unsigned long long>(v));
  return buf;
}

// Returns a tab ID scoped to a session, e.g. "a1b2c3d4-t0".
// Uses only the first 8 characters of session_id for readability.
inline std::string new_tab_id(const std::string& session_id, int index) {
  std::string prefix = session_id.size() >= 8
                           ? session_id.substr(0, 8)
                           : session_id;
  return prefix + "-t" + std::to_string(index);
}

// Returns a UUID v4, e.g. "550e8400-e29b-41d4-a716-446655440000".
// Used for request_id fields where a full UUID is needed.
inline std::string new_uuid() {
  uint8_t bytes[16];
  arc4random_buf(bytes, sizeof(bytes));

  // Set version 4 and variant bits
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  char buf[37];
  std::snprintf(buf, sizeof(buf),
    "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    bytes[0], bytes[1], bytes[2],  bytes[3],
    bytes[4], bytes[5],
    bytes[6], bytes[7],
    bytes[8], bytes[9],
    bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);
  return buf;
}

// Returns the current Unix time in milliseconds.
inline int64_t now_ms() {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 +
         static_cast<int64_t>(ts.tv_nsec) / 1000000;
}

}  // namespace id_utils
