<template>
  <div class="tabs-chat-panel">
    <!-- Tab list -->
    <div class="tabs-section">
      <div class="debug-banner">This is the Tabs &amp; Chat window (Vue)</div>
      <div class="section-label">Tabs</div>
      <div class="tab-list">
        <div
          v-for="(tab, i) in tabs"
          :key="tab.id"
          class="tab-item"
          :class="{ active: i === activeTab }"
          @click="switchTab(i)"
        >
          <span class="tab-title">{{ tab.title }}</span>
          <button class="tab-close" @click.stop="closeTab(i)">×</button>
        </div>
      </div>
      <button class="new-tab-btn" @click="newTab">+ New Tab</button>
    </div>

    <!-- Chat -->
    <div class="chat-section">
      <div class="section-label">Agent Chat</div>
      <div class="chat-messages" ref="chatEl">
        <div
          v-for="msg in messages"
          :key="msg.id"
          class="message"
          :class="msg.role"
        >
          <div class="message-bubble">{{ msg.text }}</div>
        </div>
      </div>
      <div class="chat-input-row">
        <input
          v-model="draft"
          class="chat-input"
          placeholder="Ask the agent…"
          @keydown.enter="sendMessage"
        />
        <button class="send-btn" @click="sendMessage">↑</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, nextTick } from 'vue'

interface Tab {
  id: number
  title: string
}

interface Message {
  id: number
  role: 'user' | 'assistant'
  text: string
}

const tabs = ref<Tab[]>([
  { id: 1, title: 'New Tab' },
])
const activeTab = ref(0)

const messages = ref<Message[]>([
  { id: 1, role: 'assistant', text: "Hello! I'm your browser agent. How can I help?" },
])
const draft = ref('')
const chatEl = ref<HTMLDivElement | null>(null)

let nextTabId = 2
let nextMsgId = 2

function switchTab(i: number): void {
  activeTab.value = i
}

function closeTab(i: number): void {
  if (tabs.value.length === 1) return
  tabs.value.splice(i, 1)
  if (activeTab.value >= tabs.value.length)
    activeTab.value = tabs.value.length - 1
}

function newTab(): void {
  tabs.value.push({ id: nextTabId++, title: 'New Tab' })
  activeTab.value = tabs.value.length - 1
}

async function sendMessage(): Promise<void> {
  const text = draft.value.trim()
  if (!text) return
  draft.value = ''
  messages.value.push({ id: nextMsgId++, role: 'user', text })
  await nextTick()
  chatEl.value?.scrollTo({ top: chatEl.value.scrollHeight, behavior: 'smooth' })

  // Placeholder echo.
  setTimeout(() => {
    messages.value.push({ id: nextMsgId++, role: 'assistant', text: `(echo) ${text}` })
    void nextTick(() => chatEl.value?.scrollTo({ top: chatEl.value!.scrollHeight, behavior: 'smooth' }))
  }, 400)
}
</script>

<style>
* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: #1a1a1a;
  color: #e0e0e0;
  height: 100vh;
  overflow: hidden;
}

.tabs-chat-panel {
  display: flex;
  flex-direction: column;
  height: 100vh;
}

.section-label {
  font-size: 11px;
  font-weight: 600;
  color: #888;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 10px 12px 6px;
}

.debug-banner {
  background: #1a3c5c;
  color: #7ec7ff;
  font-size: 11px;
  padding: 4px 8px;
  border-radius: 4px;
  margin: 6px 12px 0;
  font-family: monospace;
  border: 1px solid #3a7cac;
}

/* ----- Tabs section ----- */
.tabs-section {
  border-bottom: 1px solid #333;
  padding-bottom: 6px;
}

.tab-list {
  max-height: 180px;
  overflow-y: auto;
}

.tab-item {
  display: flex;
  align-items: center;
  padding: 7px 12px;
  cursor: pointer;
  border-radius: 6px;
  margin: 2px 6px;
  font-size: 13px;
  transition: background 0.15s;
}

.tab-item:hover { background: #2a2a2a; }
.tab-item.active { background: #2d4a7a; }

.tab-title {
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.tab-close {
  flex-shrink: 0;
  background: none;
  border: none;
  color: #888;
  font-size: 14px;
  cursor: pointer;
  padding: 0 2px;
  line-height: 1;
}
.tab-close:hover { color: #e0e0e0; }

.new-tab-btn {
  width: calc(100% - 12px);
  margin: 4px 6px 0;
  padding: 6px;
  background: #2a2a2a;
  border: 1px solid #444;
  border-radius: 6px;
  color: #e0e0e0;
  font-size: 12px;
  cursor: pointer;
}
.new-tab-btn:hover { background: #333; }

/* ----- Chat section ----- */
.chat-section {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.chat-messages {
  flex: 1;
  overflow-y: auto;
  padding: 8px 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.message { display: flex; }
.message.user { justify-content: flex-end; }
.message.assistant { justify-content: flex-start; }

.message-bubble {
  max-width: 85%;
  padding: 8px 11px;
  border-radius: 12px;
  font-size: 13px;
  line-height: 1.4;
}

.message.user .message-bubble {
  background: #2d4a7a;
  color: #e8f0ff;
}

.message.assistant .message-bubble {
  background: #2a2a2a;
  color: #e0e0e0;
}

.chat-input-row {
  display: flex;
  gap: 6px;
  padding: 8px 6px;
  border-top: 1px solid #333;
}

.chat-input {
  flex: 1;
  background: #2a2a2a;
  border: 1px solid #444;
  border-radius: 8px;
  color: #e0e0e0;
  font-size: 13px;
  padding: 7px 10px;
  outline: none;
}
.chat-input:focus { border-color: #4a7aaa; }

.send-btn {
  background: #2d4a7a;
  border: none;
  border-radius: 8px;
  color: #e8f0ff;
  font-size: 16px;
  width: 34px;
  cursor: pointer;
  flex-shrink: 0;
}
.send-btn:hover { background: #3a5a8a; }
</style>
