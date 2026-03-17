<template>
  <div class="sessions-panel">
    <div class="panel-header">
      <h2>Sessions</h2>
      <div class="debug-banner">This is the Sessions page (Vue)</div>
    </div>
    <div class="session-list">
      <div
        v-for="session in sessions"
        :key="session.id"
        class="session-item"
        :class="{ active: session.active }"
        @click="selectSession(session)"
      >
        <div class="session-icon">{{ session.icon }}</div>
        <div class="session-info">
          <div class="session-name">{{ session.name }}</div>
          <div class="session-url">{{ session.url }}</div>
        </div>
      </div>
    </div>
    <div class="panel-footer">
      <button class="new-session-btn" @click="newSession">+ New Session</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'

interface Session {
  id: number
  name: string
  url: string
  icon: string
  active: boolean
}

const sessions = ref<Session[]>([
  { id: 1, name: 'Research', url: 'google.com', icon: '🔍', active: true },
  { id: 2, name: 'Work',     url: 'github.com', icon: '💼', active: false },
])

function selectSession(session: Session): void {
  sessions.value.forEach(s => { s.active = false })
  session.active = true
}

function newSession(): void {
  const id = Date.now()
  sessions.value.push({ id, name: 'New Session', url: '', icon: '🌐', active: false })
}
</script>

<style>
* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: #181c1f;
  color: #e0e0e0;
  height: 100vh;
  overflow: hidden;
}

.sessions-panel {
  display: flex;
  flex-direction: column;
  height: 100vh;
}

.panel-header {
  padding: 16px 12px 8px;
  border-bottom: 1px solid #333;
}

.debug-banner {
  background: #1a5c3a;
  color: #7effc7;
  font-size: 11px;
  padding: 4px 8px;
  border-radius: 4px;
  margin-top: 6px;
  font-family: monospace;
  border: 1px solid #3a9c6a;
}

.panel-header h2 {
  font-size: 13px;
  font-weight: 600;
  color: #aaa;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.session-list {
  flex: 1;
  overflow-y: auto;
  padding: 4px 0;
}

.session-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 12px;
  cursor: pointer;
  border-radius: 6px;
  margin: 2px 6px;
  transition: background 0.15s;
}

.session-item:hover {
  background: #2a2a2a;
}

.session-item.active {
  background: #2d4a7a;
}

.session-icon {
  font-size: 18px;
  flex-shrink: 0;
}

.session-info {
  min-width: 0;
}

.session-name {
  font-size: 13px;
  font-weight: 500;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.session-url {
  font-size: 11px;
  color: #888;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-top: 2px;
}

.panel-footer {
  padding: 8px 6px;
  border-top: 1px solid #333;
}

.new-session-btn {
  width: 100%;
  padding: 8px;
  background: #2a2a2a;
  border: 1px solid #444;
  border-radius: 6px;
  color: #e0e0e0;
  font-size: 12px;
  cursor: pointer;
  transition: background 0.15s;
}

.new-session-btn:hover {
  background: #333;
}
</style>
