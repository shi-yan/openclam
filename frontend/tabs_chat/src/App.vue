<template>
  <div class="panel">

    <!-- ── Navigation bar ─────────────────────────────────── -->
    <div class="nav-bar">
      <button class="nav-btn" title="Back" @click="goBack" :disabled="!canGoBack">
        <svg viewBox="0 0 20 20" width="15" height="15" fill="none"
             stroke="currentColor" stroke-width="2.2"
             stroke-linecap="round" stroke-linejoin="round">
          <polyline points="12,4 7,10 12,16"/>
        </svg>
      </button>
      <button class="nav-btn" title="Forward" @click="goForward" :disabled="!canGoForward">
        <svg viewBox="0 0 20 20" width="15" height="15" fill="none"
             stroke="currentColor" stroke-width="2.2"
             stroke-linecap="round" stroke-linejoin="round">
          <polyline points="8,4 13,10 8,16"/>
        </svg>
      </button>
      <button class="nav-btn" title="Reload" @click="reload">
        <svg viewBox="0 0 20 20" width="15" height="15" fill="none"
             stroke="currentColor" stroke-width="2.2"
             stroke-linecap="round" stroke-linejoin="round">
          <path d="M15.5 5A7.5 7.5 0 1 1 4.5 10.5"/>
          <polyline points="4,4.5 4.5,10.5 10.5,10"/>
        </svg>
      </button>
      <input
        class="address-bar"
        v-model="urlDraft"
        placeholder="Search or enter address"
        spellcheck="false"
        autocomplete="off"
        @keydown.enter.prevent="navigate"
        @focus="selectAll"
      />
    </div>

    <!-- ── Tab list (resizable) ───────────────────────────── -->
    <transition name="tabs-fade">
      <div
        v-show="tabsVisible"
        class="tabs-section"
        :style="{ height: tabsHeight + 'px' }"
        ref="tabsSectionEl"
      >
        <div class="tab-list" ref="tabListEl">
          <div
            v-for="(tab, i) in tabs"
            :key="tab.id"
            class="tab-item"
            :class="{ active: i === activeTab }"
            @click="switchTab(i)"
          >
            <span class="tab-favicon">
              <img v-if="tab.faviconDataUrl" :src="tab.faviconDataUrl"
                   class="tab-favicon-img" alt="">
              <span v-else>{{ tab.favicon }}</span>
            </span>
            <span class="tab-title">{{ tab.title }}</span>
            <button
              class="tab-close"
              @click.stop="closeTab(i)"
              :disabled="tabs.length === 1"
              title="Close tab"
            >
              <svg viewBox="0 0 12 12" width="9" height="9" fill="none"
                   stroke="currentColor" stroke-width="1.8"
                   stroke-linecap="round">
                <line x1="2" y1="2" x2="10" y2="10"/>
                <line x1="10" y1="2" x2="2" y2="10"/>
              </svg>
            </button>
          </div>
        </div>

        <div class="new-tab-row">
          <button class="new-tab-btn" @click="newTab">
            <svg viewBox="0 0 14 14" width="11" height="11" fill="none"
                 stroke="currentColor" stroke-width="2"
                 stroke-linecap="round">
              <line x1="7" y1="1" x2="7" y2="13"/>
              <line x1="1" y1="7" x2="13" y2="7"/>
            </svg>
            New Tab
          </button>
        </div>
      </div>
    </transition>

    <!-- ── Drag divider ───────────────────────────────────── -->
    <div
      v-show="tabsVisible"
      class="drag-divider"
      :class="{ dragging: isDragging }"
      @mousedown.prevent="startDrag"
    ></div>

    <!-- ── Chat section ───────────────────────────────────── -->
    <div class="chat-section">
      <div class="chat-messages" ref="chatEl">
        <div
          v-for="msg in messages"
          :key="msg.id"
          class="message"
          :class="msg.role"
        >
          <div class="bubble" v-html="msg.html"></div>
        </div>
      </div>

      <!-- Input row -->
      <div class="input-row">
        <button
          class="toggle-btn"
          :class="{ active: tabsVisible }"
          @click="toggleTabs"
          title="Toggle tabs panel"
        >
          <svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor">
            <rect x="1" y="2" width="5.5" height="12" rx="1.5"/>
            <rect x="9.5" y="2" width="5.5" height="12" rx="1.5"
                  :opacity="tabsVisible ? '0.85' : '0.3'"/>
          </svg>
        </button>

        <textarea
          ref="inputEl"
          v-model="draft"
          class="chat-input"
          placeholder="Ask the agent…"
          rows="1"
          @keydown.enter.exact.prevent="sendMessage"
          @input="autoResize"
        ></textarea>

        <button
          class="send-btn"
          @click="sendMessage"
          :disabled="!draft.trim()"
          title="Send"
        >
          <svg viewBox="0 0 16 16" width="14" height="14" fill="none"
               stroke="currentColor" stroke-width="2.2"
               stroke-linecap="round" stroke-linejoin="round">
            <line x1="8" y1="13" x2="8" y2="3"/>
            <polyline points="4,7 8,3 12,7"/>
          </svg>
        </button>
      </div>
    </div>

  </div>
</template>

<script setup lang="ts">
import { ref, nextTick, onMounted } from 'vue'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
interface Tab {
  id: number
  title: string
  url: string
  favicon: string        // emoji placeholder
  faviconDataUrl: string // base64 data URL once downloaded, empty until then
}

interface Message {
  id: number
  role: 'user' | 'assistant'
  html: string
}

// ---------------------------------------------------------------------------
// CEF bridge
// ---------------------------------------------------------------------------
declare global {
  interface Window {
    cefQuery?: (opts: {
      request: string
      onSuccess: (r: string) => void
      onFailure: (code: number, msg: string) => void
    }) => number
    cefQueryCancel?: (id: number) => void
  }
}

function cefSend(request: string, onSuccess?: (r: string) => void) {
  if (typeof window.cefQuery !== 'undefined') {
    window.cefQuery({
      request,
      onSuccess: onSuccess ?? (() => {}),
      onFailure: () => {},
    })
  }
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
const tabs = ref<Tab[]>([
  { id: 1, title: 'New Tab', url: '', favicon: '📄', faviconDataUrl: '' },
])
const activeTab    = ref(0)
const urlDraft     = ref('')
const canGoBack    = ref(false)
const canGoForward = ref(false)

const messages = ref<Message[]>([
  { id: 1, role: 'assistant',
    html: "Hello! I'm your browser agent. How can I help?" },
])
const draft  = ref('')
const chatEl = ref<HTMLDivElement | null>(null)
const inputEl = ref<HTMLTextAreaElement | null>(null)

// Tab panel resize state
const tabsVisible  = ref(true)
const tabsHeight   = ref(220)
const isDragging   = ref(false)
let dragStartY     = 0
let dragStartH     = 0

let nextTabId  = 2
let nextMsgId  = 2

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------
function goBack()    { cefSend('browser-nav:back') }
function goForward() { cefSend('browser-nav:forward') }
function reload()    { cefSend('browser-nav:reload') }

function navigate() {
  const url = urlDraft.value.trim()
  if (!url) return
  // Prepend https:// if no scheme
  const target = /^https?:\/\//i.test(url) ? url : `https://${url}`
  cefSend('browser-nav:load:' + target)
  tabs.value[activeTab.value].url = target
}

function selectAll(e: FocusEvent) {
  (e.target as HTMLInputElement).select()
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------
function switchTab(i: number) {
  activeTab.value = i
  urlDraft.value  = tabs.value[i].url
  cefSend('browser-nav:switch:' + i)
}

function closeTab(i: number) {
  if (tabs.value.length === 1) return
  cefSend('browser-nav:close:' + i)
  tabs.value.splice(i, 1)
  if (activeTab.value >= tabs.value.length)
    activeTab.value = tabs.value.length - 1
}

function newTab() {
  const id = nextTabId++
  tabs.value.push({ id, title: 'New Tab', url: '', favicon: '📄', faviconDataUrl: '' })
  activeTab.value = tabs.value.length - 1
  urlDraft.value  = ''
  cefSend('browser-nav:new-tab')
}

// ---------------------------------------------------------------------------
// Drag-to-resize divider
// ---------------------------------------------------------------------------
function startDrag(e: MouseEvent) {
  isDragging.value = true
  dragStartY = e.clientY
  dragStartH = tabsHeight.value

  const onMove = (ev: MouseEvent) => {
    const delta = ev.clientY - dragStartY
    tabsHeight.value = Math.max(80, Math.min(560, dragStartH + delta))
  }

  const onUp = () => {
    isDragging.value = false
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
  }

  document.addEventListener('mousemove', onMove)
  document.addEventListener('mouseup', onUp)
}

function toggleTabs() {
  tabsVisible.value = !tabsVisible.value
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\n/g, '<br>')
}

async function sendMessage() {
  const text = draft.value.trim()
  if (!text) return
  draft.value = ''
  resetInputHeight()
  messages.value.push({ id: nextMsgId++, role: 'user', html: escapeHtml(text) })
  await scrollChat()
  cefSend('agent:send:' + JSON.stringify({ text }))

  // Placeholder echo until real agent bridge.
  setTimeout(async () => {
    messages.value.push({
      id: nextMsgId++,
      role: 'assistant',
      html: `<em style="opacity:.6">(echo)</em> ${escapeHtml(text)}`,
    })
    await scrollChat()
  }, 400)
}

async function scrollChat() {
  await nextTick()
  chatEl.value?.scrollTo({ top: chatEl.value.scrollHeight, behavior: 'smooth' })
}

function autoResize() {
  const el = inputEl.value
  if (!el) return
  el.style.height = 'auto'
  el.style.height = Math.min(el.scrollHeight, 120) + 'px'
}

function resetInputHeight() {
  if (inputEl.value) inputEl.value.style.height = ''
}

// ---------------------------------------------------------------------------
// Receive messages from native layer via window.__openclam_post
// ---------------------------------------------------------------------------
onMounted(() => {
  // The native layer can call window.__openclam_post({ type, payload }) from JS.
  ;(window as any).__openclam_post = (msg: { type: string; payload: unknown }) => {
    if (msg.type === 'url-changed') {
      const { tabId, url, title } = msg.payload as { tabId: number; url: string; title: string }
      const t = tabs.value.find(t => t.id === tabId)
      if (t) {
        t.url   = url
        t.title = title || url
        if (tabs.value.indexOf(t) === activeTab.value)
          urlDraft.value = url
      }
    } else if (msg.type === 'active-nav-state') {
      const { url, title, faviconDataUrl, canGoBack: back, canGoForward: fwd, isLoading } =
        msg.payload as {
          url: string; title: string; faviconDataUrl: string
          canGoBack: boolean; canGoForward: boolean; isLoading: boolean
        }
      const tab = tabs.value[activeTab.value]
      if (tab) {
        tab.url   = url
        tab.title = title || url
        // Reset favicon when a new navigation starts; apply once downloaded.
        if (isLoading && !faviconDataUrl) tab.faviconDataUrl = ''
        else if (faviconDataUrl)          tab.faviconDataUrl = faviconDataUrl
      }
      urlDraft.value     = url
      canGoBack.value    = back
      canGoForward.value = fwd
    } else if (msg.type === 'agent-message') {
      const { html } = msg.payload as { html: string }
      messages.value.push({ id: nextMsgId++, role: 'assistant', html })
      void scrollChat()
    }
  }
})
</script>

<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: #131315;
  color: #dddde0;
  height: 100vh;
  overflow: hidden;
  -webkit-font-smoothing: antialiased;
}

/* ── Layout ──────────────────────────────────────────────── */
.panel {
  display: flex;
  flex-direction: column;
  height: 100vh;
}

/* ── Navigation bar ──────────────────────────────────────── */
.nav-bar {
  display: flex;
  align-items: center;
  gap: 2px;
  padding: 6px 8px;
  flex-shrink: 0;
  border-bottom: 1px solid rgba(255,255,255,0.055);
}

.nav-btn {
  flex-shrink: 0;
  background: none;
  border: none;
  color: rgba(255,255,255,0.38);
  width: 28px;
  height: 28px;
  border-radius: 6px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: color .12s, background .12s;
}
.nav-btn:hover  { background: rgba(255,255,255,0.08); color: rgba(255,255,255,0.82); }
.nav-btn:active { background: rgba(255,255,255,0.13); }
.nav-btn:disabled { opacity: 0.22; cursor: default; pointer-events: none; }

.address-bar {
  flex: 1;
  background: rgba(255,255,255,0.07);
  border: 1px solid transparent;
  border-radius: 7px;
  color: #dddde0;
  font-size: 12px;
  padding: 5px 9px;
  outline: none;
  transition: background .14s, border-color .14s;
  min-width: 0;
  user-select: text;
  -webkit-user-select: text;
}
.address-bar:focus {
  background: rgba(255,255,255,0.1);
  border-color: rgba(91,138,245,0.55);
}
.address-bar::placeholder { color: rgba(255,255,255,0.26); }

/* ── Tab section ─────────────────────────────────────────── */
.tabs-section {
  display: flex;
  flex-direction: column;
  overflow: hidden;
  flex-shrink: 0;
}

.tabs-fade-enter-active,
.tabs-fade-leave-active { transition: opacity .15s, height .15s; }
.tabs-fade-enter-from,
.tabs-fade-leave-to     { opacity: 0; }

.tab-list {
  flex: 1;
  overflow-y: auto;
  padding: 3px 0 2px;
  scrollbar-width: thin;
  scrollbar-color: rgba(255,255,255,0.12) transparent;
}
.tab-list::-webkit-scrollbar { width: 4px; }
.tab-list::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 2px; }

.tab-item {
  display: flex;
  align-items: center;
  gap: 7px;
  height: 33px;
  padding: 0 10px 0 10px;
  border-radius: 7px;
  margin: 1px 5px;
  cursor: pointer;
  position: relative;
  transition: background .11s;
}
.tab-item:hover   { background: rgba(255,255,255,0.06); }
.tab-item.active  { background: rgba(255,255,255,0.10); }
.tab-item.active::before {
  content: '';
  position: absolute;
  left: 0; top: 7px; bottom: 7px;
  width: 3px;
  border-radius: 0 2px 2px 0;
  background: #5b8af5;
}

.tab-favicon {
  font-size: 12px;
  flex-shrink: 0;
  width: 15px;
  height: 15px;
  text-align: center;
  line-height: 1;
  display: flex;
  align-items: center;
  justify-content: center;
}

.tab-favicon-img {
  width: 14px;
  height: 14px;
  object-fit: contain;
  border-radius: 2px;
}

.tab-title {
  flex: 1;
  font-size: 12.5px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  color: #b8b8bd;
}
.tab-item.active .tab-title {
  color: #dddde0;
  font-weight: 500;
}

.tab-close {
  flex-shrink: 0;
  background: none;
  border: none;
  color: rgba(255,255,255,0.3);
  width: 20px;
  height: 20px;
  border-radius: 5px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  opacity: 0;
  transition: opacity .11s, background .11s, color .11s;
}
.tab-item:hover .tab-close  { opacity: 1; }
.tab-item.active .tab-close { opacity: 0.6; }
.tab-close:hover  {
  background: rgba(255,255,255,0.1);
  color: #dddde0;
  opacity: 1 !important;
}
.tab-close:disabled { opacity: 0 !important; cursor: default; }

.new-tab-row {
  padding: 3px 7px 5px;
  border-top: 1px solid rgba(255,255,255,0.055);
  flex-shrink: 0;
}

.new-tab-btn {
  display: flex;
  align-items: center;
  gap: 6px;
  width: 100%;
  padding: 5px 8px;
  background: none;
  border: none;
  border-radius: 6px;
  color: rgba(255,255,255,0.36);
  font-size: 12px;
  cursor: pointer;
  transition: background .12s, color .12s;
}
.new-tab-btn:hover {
  background: rgba(255,255,255,0.07);
  color: rgba(255,255,255,0.7);
}

/* ── Drag divider ────────────────────────────────────────── */
.drag-divider {
  height: 6px;
  flex-shrink: 0;
  cursor: ns-resize;
  position: relative;
  z-index: 10;
}
.drag-divider::after {
  content: '';
  position: absolute;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  width: 36px;
  height: 3px;
  border-radius: 2px;
  background: rgba(255,255,255,0.12);
  transition: background .14s;
}
.drag-divider:hover::after   { background: rgba(255,255,255,0.28); }
.drag-divider.dragging::after { background: #5b8af5; }

/* ── Chat section ────────────────────────────────────────── */
.chat-section {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.chat-messages {
  flex: 1;
  overflow-y: auto;
  padding: 10px 10px 6px;
  display: flex;
  flex-direction: column;
  gap: 5px;
  scrollbar-width: thin;
  scrollbar-color: rgba(255,255,255,0.1) transparent;
}
.chat-messages::-webkit-scrollbar { width: 4px; }
.chat-messages::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.1); border-radius: 2px; }

.message { display: flex; }
.message.user      { justify-content: flex-end; }
.message.assistant { justify-content: flex-start; }

.bubble {
  max-width: 88%;
  padding: 7px 11px;
  border-radius: 12px;
  font-size: 13px;
  line-height: 1.5;
  user-select: text;
  -webkit-user-select: text;
  word-break: break-word;
}
.message.user .bubble {
  background: #2a52d4;
  color: #ecefff;
  border-radius: 12px 12px 3px 12px;
}
.message.assistant .bubble {
  background: rgba(255,255,255,0.08);
  color: #d8d8dc;
  border-radius: 12px 12px 12px 3px;
}

/* ── Input row ───────────────────────────────────────────── */
.input-row {
  display: flex;
  align-items: flex-end;
  gap: 5px;
  padding: 6px 7px 7px;
  border-top: 1px solid rgba(255,255,255,0.055);
  background: rgba(0,0,0,0.18);
  flex-shrink: 0;
}

.toggle-btn {
  flex-shrink: 0;
  background: none;
  border: none;
  color: rgba(255,255,255,0.32);
  width: 28px;
  height: 28px;
  border-radius: 6px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: color .12s, background .12s;
  margin-bottom: 2px;
  align-self: flex-end;
}
.toggle-btn:hover  { background: rgba(255,255,255,0.08); color: rgba(255,255,255,0.65); }
.toggle-btn.active { color: #5b8af5; }
.toggle-btn.active:hover { color: #7aa6f8; }

.chat-input {
  flex: 1;
  background: rgba(255,255,255,0.07);
  border: 1px solid transparent;
  border-radius: 9px;
  color: #dddde0;
  font-size: 13px;
  font-family: inherit;
  line-height: 1.45;
  padding: 6px 10px;
  outline: none;
  resize: none;
  overflow-y: hidden;
  min-height: 32px;
  max-height: 120px;
  transition: background .14s, border-color .14s;
  user-select: text;
  -webkit-user-select: text;
}
.chat-input:focus {
  background: rgba(255,255,255,0.1);
  border-color: rgba(91,138,245,0.45);
  overflow-y: auto;
}
.chat-input::placeholder { color: rgba(255,255,255,0.24); }

.send-btn {
  flex-shrink: 0;
  background: #5b8af5;
  border: none;
  border-radius: 7px;
  color: #fff;
  width: 30px;
  height: 30px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background .13s, transform .1s;
  align-self: flex-end;
  margin-bottom: 1px;
}
.send-btn:hover   { background: #6b9af7; }
.send-btn:active  { transform: scale(0.94); }
.send-btn:disabled {
  background: rgba(255,255,255,0.09);
  cursor: not-allowed;
  transform: none;
}
</style>
