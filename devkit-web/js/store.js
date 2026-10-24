/* ==========================================================================
   会话状态：localStorage 持久化（HTTP 历史另存 IndexedDB）
   ========================================================================== */

import { uid, debounce } from './ui/dom.js';
import { defaultRequest } from './tools/http/model.js';

const KEY = 'devkit.web.state.v1';

export { defaultRequest };

export function defaultHTTPData() {
  return {
    request: defaultRequest(),
    savedRequestId: null,
    savedFolderId: null,
    lastSavedRequest: null,
  };
}

export function defaultJSONData() {
  return {
    text: '',
    mode: 'code',
    indent: 'spaces2',
  };
}

const DEFAULT_STATE = {
  version: 1,
  appearance: 'system',
  sidebarWidth: 208,
  httpEditorRatio: 0.5,
  proxyMode: 'auto',
  wakeLock: false,
  tabs: [],
  groups: [],
  selectedTabId: null,
  launcherOpen: true,
  recentTools: {},
  httpCollections: { folders: [], requests: [] },
};

function cloneDefaults() {
  return JSON.parse(JSON.stringify(DEFAULT_STATE));
}

function normalize(raw) {
  const state = { ...cloneDefaults(), ...(raw && typeof raw === 'object' ? raw : {}) };
  state.version = 1;
  if (!Array.isArray(state.tabs)) state.tabs = [];
  if (!Array.isArray(state.groups)) state.groups = [];
  if (!state.httpCollections || typeof state.httpCollections !== 'object') {
    state.httpCollections = { folders: [], requests: [] };
  }
  if (!Array.isArray(state.httpCollections.folders)) state.httpCollections.folders = [];
  if (!Array.isArray(state.httpCollections.requests)) state.httpCollections.requests = [];

  state.tabs = state.tabs
    .filter((tab) => tab && tab.id && tab.toolId)
    .map((tab) => ({
      id: tab.id,
      toolId: tab.toolId,
      title: typeof tab.title === 'string' ? tab.title : null,
      customTitle: typeof tab.customTitle === 'string' ? tab.customTitle : null,
      groupId: tab.groupId ?? null,
      data: tab.data && typeof tab.data === 'object' ? tab.data : {},
    }));

  state.groups = state.groups
    .filter((g) => g && g.id)
    .map((g) => ({
      id: g.id,
      name: typeof g.name === 'string' ? g.name : '分组',
      color: typeof g.color === 'string' ? g.color : 'blue',
      collapsed: Boolean(g.collapsed),
    }));

  // 选中的标签可能已不存在
  if (!state.tabs.some((t) => t.id === state.selectedTabId)) {
    state.selectedTabId = state.tabs.length ? state.tabs[state.tabs.length - 1].id : null;
  }
  if (!state.tabs.length) {
    state.selectedTabId = null;
    state.launcherOpen = true;
  }
  state.sidebarWidth = Math.min(340, Math.max(168, Number(state.sidebarWidth) || 208));
  state.httpEditorRatio = Math.min(0.88, Math.max(0.12, Number(state.httpEditorRatio) || 0.5));
  return state;
}

export const store = {
  state: cloneDefaults(),
  ready: false,
  listeners: new Set(),

  load() {
    try {
      const raw = localStorage.getItem(KEY);
      this.state = normalize(raw ? JSON.parse(raw) : null);
    } catch (error) {
      console.warn('[devkit] 读取会话失败，使用默认状态', error);
      this.state = cloneDefaults();
    }
    this.ready = true;
    return this.state;
  },

  emit() {
    for (const listener of this.listeners) listener(this.state);
  },

  onChange(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  },

  save: debounce(function () {
    try {
      localStorage.setItem(KEY, JSON.stringify(store.state));
    } catch (error) {
      console.warn('[devkit] 保存会话失败', error);
    }
    store.emit();
  }, 220),

  saveNow() {
    this.save.cancel();
    try {
      localStorage.setItem(KEY, JSON.stringify(this.state));
    } catch (error) {
      console.warn('[devkit] 保存会话失败', error);
    }
  },

  touch() {
    this.save();
  },

  replace(raw) {
    this.state = normalize(raw);
    this.saveNow();
    this.emit();
  },

  reset() {
    this.state = cloneDefaults();
    this.saveNow();
    this.emit();
  },
};

/* — 集合辅助 — */

export function allFolders(state = store.state) {
  return state.httpCollections.folders;
}

export function folderPath(folderId, state = store.state) {
  const names = [];
  let id = folderId;
  let guard = 0;
  while (id && guard < 20) {
    const folder = state.httpCollections.folders.find((f) => f.id === id);
    if (!folder) break;
    names.unshift(folder.name);
    id = folder.parentId;
    guard += 1;
  }
  return names.join(' / ');
}

export function folderOptions(state = store.state) {
  const folders = state.httpCollections.folders;
  const result = [{ id: null, label: '根目录', depth: 0 }];
  const walk = (parentId, depth) => {
    for (const folder of folders.filter((f) => (f.parentId ?? null) === parentId)) {
      result.push({ id: folder.id, label: folder.name, depth });
      walk(folder.id, depth + 1);
    }
  };
  walk(null, 1);
  return result;
}

export function createFolder(name, parentId) {
  const folder = { id: uid('folder'), name: name.trim(), parentId: parentId ?? null };
  if (!folder.name) return null;
  store.state.httpCollections.folders.push(folder);
  store.touch();
  return folder;
}

export function deleteFolderCascade(folderId) {
  const collections = store.state.httpCollections;
  const doomed = new Set([folderId]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const folder of collections.folders) {
      if (folder.parentId && doomed.has(folder.parentId) && !doomed.has(folder.id)) {
        doomed.add(folder.id);
        changed = true;
      }
    }
  }
  const removedRequestIds = new Set(
    collections.requests.filter((r) => doomed.has(r.folderId)).map((r) => r.id)
  );
  collections.requests = collections.requests.filter((r) => !removedRequestIds.has(r.id));
  collections.folders = collections.folders.filter((f) => !doomed.has(f.id));
  store.touch();
  return removedRequestIds;
}

/* — 导入 / 导出 — */

export function exportState() {
  return JSON.stringify({ kind: 'devkit-web-export', at: Date.now(), state: store.state }, null, 2);
}
