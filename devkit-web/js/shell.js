/* ==========================================================================
   应用外壳：侧栏标签、分组、Launcher、快捷键、主题、会话
   ========================================================================== */

import {
  h,
  icon,
  uid,
  clamp,
  isMac,
  modKey,
  downloadFile,
} from './ui/dom.js';
import { openMenu, openModal, promptDialog, toast, confirmDialog } from './ui/overlay.js';
import { store } from './store.js';
import { TOOLS, CATEGORY_ORDER, toolById, desktopReason } from './tools/registry.js';
import { requestIsEmpty } from './tools/http/model.js';
import { historyStore } from './tools/http/history.js';
import { openSettings } from './settings.js';

export const GROUP_COLORS = {
  blue: '#3b82f6',
  purple: '#8b5cf6',
  pink: '#ec4899',
  red: '#ef4444',
  orange: '#f59e0b',
  yellow: '#d6a600',
  green: '#22c55e',
  teal: '#14b8a6',
  gray: '#8b93a1',
};

const GROUP_COLOR_LABELS = {
  blue: '蓝色',
  purple: '紫色',
  pink: '粉色',
  red: '红色',
  orange: '橙色',
  yellow: '黄色',
  green: '绿色',
  teal: '青色',
  gray: '灰色',
};

export function bootApp() {
  store.load();

  const state = store.state;
  const views = new Map();
  const panes = new Map();
  let launcherQuery = '';
  let renamingId = null;
  let suppressClick = false;

  const els = {
    sidebar: document.getElementById('sidebar'),
    tabList: document.getElementById('tab-list'),
    tabScroll: document.getElementById('tab-scroll'),
    resizer: document.getElementById('sidebar-resizer'),
    paneStack: document.getElementById('pane-stack'),
    launcher: document.getElementById('launcher'),
    settings: document.getElementById('open-settings'),
    wake: document.getElementById('wake-lock'),
    footerHint: document.getElementById('footer-hint'),
    content: document.getElementById('content'),
  };

  /* ======================================================================
     主题
     ====================================================================== */

  const media = window.matchMedia('(prefers-color-scheme: dark)');

  function applyAppearance() {
    const mode = state.appearance || 'system';
    const theme = mode === 'system' ? (media.matches ? 'dark' : 'light') : mode;
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.colorScheme = theme;
  }

  media.addEventListener('change', () => {
    if (state.appearance === 'system') applyAppearance();
  });

  /* ======================================================================
     标签
     ====================================================================== */

  function tabTitle(tab) {
    if (tab.customTitle) return tab.customTitle;
    const view = views.get(tab.id);
    const dynamic = view?.getTitle?.();
    if (dynamic) return dynamic;
    return toolById(tab.toolId)?.title ?? '标签';
  }

  function tabDirty(tab) {
    return Boolean(views.get(tab.id)?.hasUnsaved?.());
  }

  function activeTab() {
    return state.tabs.find((tab) => tab.id === state.selectedTabId) ?? null;
  }

  function activeView() {
    return activeTab() ? views.get(state.selectedTabId) : null;
  }

  function ensureMounted(tab) {
    if (views.has(tab.id)) return;
    const tool = toolById(tab.toolId);
    if (!tool?.createView) return;
    const pane = h('div', { class: 'tab-pane' });
    const view = tool.createView(tab, app);
    pane.append(h('div', { class: 'surface' }, view.el));
    els.paneStack.append(pane);
    panes.set(tab.id, pane);
    views.set(tab.id, view);
  }

  function activatePane() {
    const current = state.launcherOpen ? null : state.selectedTabId;
    for (const [id, pane] of panes) {
      pane.classList.toggle('is-active', id === current);
    }
  }

  function selectTab(id, { focus = false } = {}) {
    const tab = state.tabs.find((item) => item.id === id);
    if (!tab) return;
    state.selectedTabId = id;
    state.launcherOpen = false;
    ensureMounted(tab);
    store.touch();
    renderShell();
    if (focus) views.get(id)?.focus?.();
    requestAnimationFrame(() => views.get(id)?.resize?.());
  }

  function openTool(toolId, { chooser = false, activate = true } = {}) {
    const tool = toolById(toolId);
    if (!tool || tool.desktopOnly) {
      if (tool) showDesktopOnly(tool);
      return null;
    }
    const tab = {
      id: uid('tab'),
      toolId,
      title: null,
      customTitle: null,
      groupId: null,
      data: tool.createData ? tool.createData() : {},
    };
    state.tabs.push(tab);
    if (activate) {
      state.selectedTabId = tab.id;
      state.launcherOpen = false;
    }
    store.touch();
    renderShell();
    ensureMounted(tab);
    activatePane();
    requestAnimationFrame(() => views.get(tab.id)?.resize?.());
    if (chooser) showHTTPChooser(tab);
    return tab;
  }

  async function closeTab(id, { force = false } = {}) {
    const tab = state.tabs.find((item) => item.id === id);
    if (!tab) return;
    const view = views.get(id);
    if (!force && view?.hasUnsaved?.()) {
      const ok = await confirmDialog({
        title: '该标签有未保存内容，确定关闭？',
        message: '关闭后未保存的请求改动会丢失。',
        confirmText: '关闭',
        danger: true,
      });
      if (!ok) return;
    }

    view?.destroy?.();
    views.delete(id);
    panes.get(id)?.remove();
    panes.delete(id);

    const index = state.tabs.findIndex((item) => item.id === id);
    state.tabs = state.tabs.filter((item) => item.id !== id);

    if (state.selectedTabId === id) {
      const next = state.tabs[Math.min(index, state.tabs.length - 1)] ?? state.tabs[index - 1] ?? null;
      state.selectedTabId = next?.id ?? null;
    }
    if (!state.tabs.length) {
      state.selectedTabId = null;
      state.launcherOpen = true;
    }
    store.touch();
    renderShell();
  }

  function closeGroup(groupId) {
    const members = state.tabs.filter((tab) => tab.groupId === groupId);
    if (!members.length) return;
    const dirty = members.some((tab) => tabDirty(tab));
    const doClose = async () => {
      if (dirty) {
        const ok = await confirmDialog({
          title: '关闭组内全部标签？',
          message: `组内共 ${members.length} 个标签，其中包含未保存的改动。`,
          confirmText: '全部关闭',
          danger: true,
        });
        if (!ok) return;
      }
      for (const tab of [...members]) {
        await closeTab(tab.id, { force: true });
      }
    };
    doClose();
  }

  function beginRename(tabId) {
    renamingId = tabId;
    renderSidebar();
    requestAnimationFrame(() => {
      const input = els.tabList.querySelector('.tab-rename');
      input?.focus();
      input?.select();
    });
  }

  function commitRename(value) {
    const tab = state.tabs.find((item) => item.id === renamingId);
    if (tab) {
      const text = value.trim();
      tab.customTitle = text || null;
      if (tab.toolId === 'tool.http' && views.get(tab.id)) {
        // 重命名已保存的请求时同步回集合
        const data = tab.data;
        if (data.savedRequestId) {
          const record = state.httpCollections.requests.find((item) => item.id === data.savedRequestId);
          if (record && text) record.name = text;
        }
      }
      store.touch();
      views.get(tab.id)?.refreshMeta?.();
    }
    renamingId = null;
    renderSidebar();
  }

  function createGroupWithTab(tab) {
    const name = `分组 ${state.groups.length + 1}`;
    const colorKeys = Object.keys(GROUP_COLORS);
    const group = {
      id: uid('group'),
      name,
      color: colorKeys[state.groups.length % colorKeys.length],
      collapsed: false,
    };
    state.groups.push(group);
    tab.groupId = group.id;
    store.touch();
    renderShell();
  }

  /* ======================================================================
     侧栏渲染
     ====================================================================== */

  function tabRow(tab) {
    const tool = toolById(tab.toolId);
    const group = state.groups.find((item) => item.id === tab.groupId);
    const isSelected = state.selectedTabId === tab.id && !state.launcherOpen;
    const title = tabTitle(tab);
    const dirty = tabDirty(tab);

    const titleEl =
      renamingId === tab.id
        ? h('input', {
            class: 'tab-rename',
            value: tab.customTitle ?? title,
            spellcheck: 'false',
            onclick: (event) => event.stopPropagation(),
            onkeydown: (event) => {
              if (event.key === 'Enter') {
                event.preventDefault();
                commitRename(event.target.value);
              } else if (event.key === 'Escape') {
                event.preventDefault();
                renamingId = null;
                renderSidebar();
              }
            },
            onblur: (event) => {
              if (renamingId === tab.id) commitRename(event.target.value);
            },
          })
        : h(
            'span',
            { class: 'tab-title', title: title },
            title,
            dirty ? h('span', { class: 'dirty' }, '  *') : null
          );

    const row = h(
      'div',
      {
        class: [
          'tab-row',
          isSelected ? 'is-selected' : '',
          group ? 'is-grouped' : '',
        ]
          .filter(Boolean)
          .join(' '),
        dataset: { tabId: tab.id },
        style: group ? { '--group-color': GROUP_COLORS[group.color] ?? GROUP_COLORS.blue } : null,
        title,
      },
      group ? h('span', { class: 'tab-accent' }) : null,
      icon(tool?.icon ?? 'file', 13, 'tab-icon'),
      titleEl,
      h(
        'button',
        {
          class: 'tab-close',
          title: '关闭标签 (⌘W)',
          onclick: (event) => {
            event.stopPropagation();
            closeTab(tab.id);
          },
        },
        icon('x', 10)
      )
    );

    row.addEventListener('click', () => {
      if (suppressClick) {
        suppressClick = false;
        return;
      }
      if (renamingId === tab.id) return;
      selectTab(tab.id);
    });

    row.addEventListener('dblclick', (event) => {
      if (event.target.closest('.tab-close, .tab-rename')) return;
      beginRename(tab.id);
    });

    row.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      const groupItems = state.groups
        .filter((item) => item.id !== tab.groupId)
        .map((item) => ({
          label: item.name,
          dot: GROUP_COLORS[item.color],
          run: () => {
            tab.groupId = item.id;
            store.touch();
            renderSidebar();
          },
        }));
      openMenu(row, [
        { label: '重命名…', icon: 'keyboard', run: () => beginRename(tab.id) },
        { sep: true },
        { heading: '添加到分组' },
        { label: '新建分组', icon: 'plus', run: () => createGroupWithTab(tab) },
        ...groupItems,
        tab.groupId ? { sep: true } : null,
        tab.groupId
          ? {
              label: '从分组中移除',
              icon: 'x',
              run: () => {
                tab.groupId = null;
                store.touch();
                renderSidebar();
              },
            }
          : null,
        { sep: true },
        { label: '关闭标签', icon: 'trash', danger: true, run: () => closeTab(tab.id) },
      ], { at: { x: event.clientX, y: event.clientY } });
    });

    attachDragHandlers(row, tab);

    return row;
  }

  function groupRow(group, members) {
    const containsSelected =
      group.collapsed && members.some((tab) => tab.id === state.selectedTabId) && !state.launcherOpen;
    const row = h(
      'div',
      {
        class: `group-row ${group.collapsed ? 'is-collapsed' : ''} ${containsSelected ? 'is-selected' : ''}`.trim(),
        dataset: { groupId: group.id },
        style: { '--group-color': GROUP_COLORS[group.color] ?? GROUP_COLORS.blue },
        title: group.name,
      },
      h('span', { class: 'group-dot' }),
      h('span', { class: 'group-name' }, group.name),
      h('span', { class: 'group-count' }, String(members.length)),
      icon('chevronDown', 11, 'group-chevron')
    );

    row.addEventListener('click', () => {
      group.collapsed = !group.collapsed;
      store.touch();
      renderSidebar();
    });

    row.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      openMenu(row, [
        {
          label: '重命名分组…',
          icon: 'keyboard',
          run: async () => {
            const name = await promptDialog({ title: '重命名分组', label: '分组名称', value: group.name });
            if (!name) return;
            group.name = name;
            store.touch();
            renderSidebar();
          },
        },
        { heading: '颜色' },
        ...Object.entries(GROUP_COLORS).map(([key, color]) => ({
          label: GROUP_COLOR_LABELS[key],
          dot: color,
          checked: group.color === key,
          run: () => {
            group.color = key;
            store.touch();
            renderSidebar();
          },
        })),
        { sep: true },
        { label: '关闭组内全部标签', icon: 'trash', danger: true, run: () => closeGroup(group.id) },
      ], { at: { x: event.clientX, y: event.clientY } });
    });

    return row;
  }

  function newTabRow() {
    const row = h(
      'div',
      { class: 'new-tab-row', title: '新建标签 (⌘T)' },
      h('span', { class: 'plus-box' }, icon('plus', 12)),
      h('span', null, '新建标签')
    );
    row.addEventListener('click', showLauncher);
    return row;
  }

  function renderSidebar() {
    els.tabList.replaceChildren();
    const rendered = new Set();

    for (const group of state.groups) {
      const members = state.tabs.filter((tab) => tab.groupId === group.id);
      els.tabList.append(groupRow(group, members));
      for (const tab of members) {
        rendered.add(tab.id);
        if (!group.collapsed) els.tabList.append(tabRow(tab));
      }
    }

    for (const tab of state.tabs) {
      if (rendered.has(tab.id)) continue;
      if (tab.groupId && !state.groups.some((group) => group.id === tab.groupId)) tab.groupId = null;
      els.tabList.append(tabRow(tab));
    }

    els.tabList.append(newTabRow());

    const selectedRow = els.tabList.querySelector('.tab-row.is-selected');
    if (selectedRow && !renamingId) {
      selectedRow.scrollIntoView({ block: 'nearest' });
    }
  }

  function updateSidebarTitles() {
    for (const row of els.tabList.querySelectorAll('.tab-row')) {
      const tab = state.tabs.find((item) => item.id === row.dataset.tabId);
      if (!tab) continue;
      const titleEl = row.querySelector('.tab-title');
      if (!titleEl) continue;
      const title = tabTitle(tab);
      titleEl.replaceChildren(title, tabDirty(tab) ? h('span', { class: 'dirty' }, '  *') : '');
      titleEl.title = title;
      row.title = title;
    }
    updateDocumentTitle();
  }

  /* ======================================================================
     拖拽排序
     ====================================================================== */

  let drag = null;

  function attachDragHandlers(row, tab) {
    row.addEventListener('pointerdown', (event) => {
      if (event.button !== 0 || renamingId === tab.id) return;
      if (event.target.closest('.tab-close, .tab-rename')) return;
      const startX = event.clientX;
      const startY = event.clientY;
      let started = false;

      const onMove = (moveEvent) => {
        const dx = moveEvent.clientX - startX;
        const dy = moveEvent.clientY - startY;
        if (!started && Math.hypot(dx, dy) < 5) return;
        if (!started) {
          started = true;
          startDrag(tab, row, moveEvent);
        }
        updateDrag(moveEvent);
      };

      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        if (started) {
          suppressClick = true;
          finishDrag();
          setTimeout(() => {
            suppressClick = false;
          }, 60);
        }
      };

      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    });
  }

  function startDrag(tab, row, event) {
    const ghost = h(
      'div',
      { class: 'tab-drag-ghost' },
      icon(toolById(tab.toolId)?.icon ?? 'file', 13),
      h('span', null, tabTitle(tab))
    );
    document.body.append(ghost);
    row.classList.add('is-dragging');
    drag = { tab, row, ghost, target: null };
    updateDrag(event);
  }

  function clearDropMarks() {
    document.querySelectorAll('.tab-drop-line').forEach((el) => el.remove());
    document.querySelectorAll('.tab-row.drop-into, .group-row.drop-into').forEach((el) =>
      el.classList.remove('drop-into')
    );
  }

  function updateDrag(event) {
    if (!drag) return;
    drag.ghost.style.left = `${event.clientX + 10}px`;
    drag.ghost.style.top = `${event.clientY - 12}px`;

    const under = document.elementFromPoint(event.clientX, event.clientY);
    const tabRow = under?.closest?.('.tab-row');
    const groupRowEl = under?.closest?.('.group-row');
    const newRow = under?.closest?.('.new-tab-row');

    clearDropMarks();
    drag.target = null;

    if (tabRow && tabRow !== drag.row) {
      const targetId = tabRow.dataset.tabId;
      const target = state.tabs.find((item) => item.id === targetId);
      if (!target) return;
      const rect = tabRow.getBoundingClientRect();
      const before = event.clientY < rect.top + rect.height / 2;
      const line = h('div', { class: 'tab-drop-line' });
      if (before) tabRow.before(line);
      else tabRow.after(line);
      drag.target = { type: 'tab', tab: target, before };
    } else if (groupRowEl) {
      groupRowEl.classList.add('drop-into');
      const groupId = groupRowEl.dataset.groupId;
      drag.target = { type: 'group', groupId };
    } else if (newRow) {
      const line = h('div', { class: 'tab-drop-line' });
      newRow.before(line);
      drag.target = { type: 'end' };
    }
  }

  function finishDrag() {
    if (!drag) return;
    const { tab, row, ghost, target } = drag;
    ghost.remove();
    row.classList.remove('is-dragging');
    clearDropMarks();
    drag = null;

    if (!target) return;

    const index = state.tabs.findIndex((item) => item.id === tab.id);
    if (index >= 0) state.tabs.splice(index, 1);

    if (target.type === 'tab') {
      tab.groupId = target.tab.groupId ?? null;
      let at = state.tabs.findIndex((item) => item.id === target.tab.id);
      if (at < 0) at = state.tabs.length;
      state.tabs.splice(target.before ? at : at + 1, 0, tab);
    } else if (target.type === 'group') {
      tab.groupId = target.groupId;
      const group = state.groups.find((item) => item.id === target.groupId);
      if (group) group.collapsed = false;
      const members = state.tabs.filter((item) => item.groupId === target.groupId);
      const last = members[members.length - 1];
      const at = last ? state.tabs.findIndex((item) => item.id === last.id) + 1 : state.tabs.length;
      state.tabs.splice(at, 0, tab);
    } else {
      tab.groupId = null;
      state.tabs.push(tab);
    }

    state.selectedTabId = tab.id;
    state.launcherOpen = false;
    store.touch();
    renderShell();
  }

  /* ======================================================================
     内容区 / Launcher
     ====================================================================== */

  function renderContent() {
    activatePane();
    const showLauncher = state.launcherOpen || !state.selectedTabId;
    els.launcher.classList.toggle('is-visible', showLauncher);
    if (showLauncher) renderLauncher();
    else els.launcher.replaceChildren();
  }

  function renderShell() {
    renderSidebar();
    renderContent();
    els.footerHint.textContent = `${modKey()}T 新建`;
    updateDocumentTitle();
  }

  function updateDocumentTitle() {
    if (state.launcherOpen || !state.selectedTabId) {
      document.title = 'devkit · 新建标签';
      return;
    }
    const tab = activeTab();
    document.title = tab ? `devkit · ${tabTitle(tab)}` : 'devkit';
  }

  function renderLauncher() {
    els.launcher.replaceChildren();

    const searchInput = h('input', {
      type: 'search',
      placeholder: '搜索工具…',
      spellcheck: 'false',
      value: launcherQuery,
      'aria-label': '搜索工具',
    });
    searchInput.addEventListener('input', () => {
      launcherQuery = searchInput.value;
      renderLauncherGrid(gridHost, searchInput.value);
    });

    const gridHost = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '28px' } });

    const inner = h(
      'div',
      { class: 'launcher-inner' },
      h(
        'div',
        { class: 'launcher-head' },
        h('img', { class: 'launcher-mark', src: './assets/appicon.png', alt: 'devkit' }),
        h('h1', { class: 'launcher-title' }, '新建标签'),
        h('p', { class: 'launcher-sub' }, '一个标签 = 一个工具实例，可以并行工作'),
        h('div', { class: 'launcher-search' }, icon('search', 15), searchInput),
        h(
          'div',
          { class: 'launcher-foot' },
          h('span', { class: 'kbd' }, `${modKey()}T`),
          h('span', null, '随时回到这里'),
          h('span', { style: { opacity: '0.45', margin: '0 4px' } }, '·'),
          icon('shield', 11),
          h('span', null, '数据只保存在本机浏览器')
        )
      ),
      gridHost
    );

    els.launcher.append(inner);
    renderLauncherGrid(gridHost, launcherQuery);
    requestAnimationFrame(() => searchInput.focus());
  }

  function renderLauncherGrid(host, query) {
    host.replaceChildren();
    const q = String(query || '').trim().toLowerCase();
    const filtered = TOOLS.filter((tool) => {
      if (!q) return true;
      return (
        tool.title.toLowerCase().includes(q) ||
        tool.subtitle.toLowerCase().includes(q) ||
        tool.category.toLowerCase().includes(q)
      );
    });

    if (q) {
      host.append(
        h(
          'section',
          { class: 'launcher-section' },
          h('h2', null, `搜索结果 · ${filtered.length}`),
          filtered.length
            ? h('div', { class: 'tool-grid' }, filtered.map(toolCard))
            : h(
                'div',
                { class: 'empty' },
                h('div', { class: 'empty-icon' }, icon('search', 26)),
                h('div', { class: 'empty-title' }, '没有匹配的工具'),
                h('div', { class: 'empty-desc' }, '试试「HTTP」「JSON」或「网络」。')
              )
        )
      );
      return;
    }

    for (const category of CATEGORY_ORDER) {
      const items = filtered.filter((tool) => tool.category === category);
      if (!items.length) continue;
      host.append(
        h(
          'section',
          { class: 'launcher-section' },
          h('h2', null, category),
          h('div', { class: 'tool-grid' }, items.map(toolCard))
        )
      );
    }
  }

  function toolCard(tool) {
    return h(
      'button',
      {
        class: 'tool-card',
        title: `${tool.title} — ${tool.subtitle}`,
        onclick: () => {
          if (tool.desktopOnly) {
            showDesktopOnly(tool);
            return;
          }
          openTool(tool.id, { chooser: Boolean(tool.chooser) });
        },
      },
      h('div', { class: 'tool-tile' }, icon(tool.icon, 21)),
      h(
        'div',
        { class: 'tool-card-body' },
        h(
          'div',
          { class: 'tool-card-title' },
          tool.title,
          tool.desktopOnly ? h('span', { class: 'desk-badge' }, '桌面版') : null
        ),
        h('div', { class: 'tool-card-sub' }, tool.subtitle)
      )
    );
  }

  function showLauncher() {
    state.launcherOpen = true;
    store.touch();
    renderShell();
  }

  function showDesktopOnly(tool) {
    const reason = desktopReason(tool.id);
    let modal;
    modal = openModal({
      title: `${tool.title} · 桌面版专属`,
      width: 450,
      body: h(
        'div',
        null,
        h(
          'div',
          { class: 'desk-note' },
          icon('lock', 16),
          h(
            'div',
            { class: 'desk-note-body' },
            h('strong', null, reason.title),
            h('div', { style: { marginTop: '4px' } }, reason.body)
          )
        ),
        h(
          'div',
          { class: 'hint-line', style: { marginTop: '14px' } },
          '网页版已提供功能等价的 HTTP 请求与 JSON 工具；终端、文件传输与 Git 操作需要本机系统能力，请在 macOS 客户端中使用。'
        )
      ),
      footer: [
        h('div', { class: 'spacer' }),
        h('button', { class: 'btn primary', onclick: () => modal.close() }, '知道了'),
      ],
    });
  }

  /* ======================================================================
     新建 HTTP 标签时的选择器
     ====================================================================== */

  function showHTTPChooser(tab) {
    let keepTab = false;

    const savedRequests = state.httpCollections.requests;
    const folderList = state.httpCollections.folders;

    const list = h('div', { class: 'collection-browser' });

    const requestRow = (record) =>
      h(
        'div',
        {
          class: 'cb-item',
          title: `${record.request.method} ${record.request.urlString}`,
          onclick: () => {
            openSavedIntoTab(tab, record);
            keepTab = true;
            modal.close();
          },
        },
        h('span', { class: 'cb-method', style: { color: 'var(--text-2)' } }, record.request.method),
        h('span', { class: 'cb-name' }, record.name),
        h('span', { class: 'cb-url' }, record.request.urlString)
      );

    if (!savedRequests.length) {
      list.append(
        h(
          'div',
          { class: 'empty', style: { minHeight: '120px' } },
          h('div', { class: 'empty-icon' }, icon('file', 24)),
          h('div', { class: 'empty-title' }, '还没有保存的请求'),
          h('div', { class: 'empty-desc' }, '先新建一个空白请求，按 ⌘S 即可保存到集合。')
        )
      );
    } else {
      for (const record of savedRequests.filter((item) => !item.folderId)) list.append(requestRow(record));
      const walk = (parentId, depth) => {
        for (const folder of folderList.filter((item) => (item.parentId ?? null) === parentId)) {
          list.append(
            h(
              'div',
              { class: 'cb-folder', style: { paddingLeft: `${7 + depth * 14}px` } },
              icon('folder', 12),
              h('span', null, folder.name)
            )
          );
          for (const record of savedRequests.filter((item) => item.folderId === folder.id)) {
            const row = requestRow(record);
            row.style.paddingLeft = `${7 + (depth + 1) * 14}px`;
            list.append(row);
          }
          walk(folder.id, depth + 1);
        }
      };
      walk(null, 0);
    }

    const body = h(
      'div',
      null,
      h(
        'button',
        {
          class: 'chooser-new',
          onclick: () => {
            keepTab = true;
            modal.close();
            requestAnimationFrame(() => views.get(tab.id)?.focus?.());
          },
        },
        icon('plus', 18, ''),
        h(
          'div',
          { style: { flex: '1', textAlign: 'left' } },
          h('div', { class: 'cn-title' }, '新建请求'),
          h('div', { class: 'cn-desc' }, '空白请求，可先发送再 ⌘S 保存')
        ),
        icon('chevronRight', 14)
      ),
      h('div', { class: 'section-label' }, '打开已保存'),
      h('div', { class: 'hint-line', style: { marginBottom: '7px' } }, '点击请求即可载入，并绑定到已保存的记录'),
      list
    );

    const modal = openModal({
      title: '新建 HTTP 请求',
      width: 460,
      body,
      onClose: () => {
        // 关闭选择器时保留空白标签：点击背景不应让用户丢失刚打开的标签。
        if (!keepTab) {
          const current = state.tabs.find((item) => item.id === tab.id);
          if (current && !current.data.savedRequestId && requestIsEmpty(current.data.request)) {
            requestAnimationFrame(() => views.get(tab.id)?.focus?.());
          }
        }
      },
    });
  }

  function openSavedIntoTab(tab, record) {
    tab.data.request = JSON.parse(JSON.stringify(record.request));
    tab.data.savedRequestId = record.id;
    tab.data.savedFolderId = record.folderId ?? null;
    tab.data.lastSavedRequest = JSON.parse(JSON.stringify(record.request));
    tab.customTitle = record.name;
    store.touch();
    views.get(tab.id)?.reloadData?.();
    renderShell();
    toast(`已打开「${record.name}」`, 'success', 'check');
  }

  /* ======================================================================
     设置 / 快捷键 / 防休眠
     ====================================================================== */

  function openSettingsPanel() {
    openSettings(app);
  }

  let wakeLock = null;

  async function toggleWakeLock() {
    if (!('wakeLock' in navigator)) {
      toast('当前浏览器不支持屏幕唤醒锁', 'warn', 'wifiOff');
      return;
    }
    if (state.wakeLock) {
      state.wakeLock = false;
      try {
        await wakeLock?.release();
      } catch {
        /* ignore */
      }
      wakeLock = null;
      els.wake.setAttribute('aria-pressed', 'false');
      store.touch();
      toast('已关闭防休眠', '', 'coffee');
      return;
    }
    try {
      wakeLock = await navigator.wakeLock.request('screen');
      state.wakeLock = true;
      els.wake.setAttribute('aria-pressed', 'true');
      store.touch();
      toast('防休眠已开启', 'success', 'coffee');
      wakeLock.addEventListener('release', () => {
        if (state.wakeLock) els.wake.setAttribute('aria-pressed', 'false');
      });
    } catch (error) {
      toast('无法启用防休眠：需要页面处于前台且浏览器支持', 'error', 'alert');
    }
  }

  async function restoreWakeLock() {
    if (!state.wakeLock || !('wakeLock' in navigator)) {
      els.wake.setAttribute('aria-pressed', 'false');
      return;
    }
    try {
      wakeLock = await navigator.wakeLock.request('screen');
      els.wake.setAttribute('aria-pressed', 'true');
    } catch {
      state.wakeLock = false;
      els.wake.setAttribute('aria-pressed', 'false');
    }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.wakeLock && !wakeLock) {
      restoreWakeLock();
    }
  });

  function initShortcuts() {
    document.addEventListener('keydown', (event) => {
      if (event.defaultPrevented) return;
      // 弹层打开时只保留弹层自身的 Esc，避免快捷键操作到背后的标签
      if (document.querySelector('.overlay')) return;

      if (event.key === 'Escape' && state.launcherOpen) {
        const tab = state.tabs[state.tabs.length - 1];
        if (tab) {
          event.preventDefault();
          selectTab(tab.id);
        }
        return;
      }

      const meta = isMac ? event.metaKey : event.ctrlKey;

      if (meta && !event.shiftKey && event.key.toLowerCase() === 't') {
        event.preventDefault();
        showLauncher();
        return;
      }

      if (meta && event.key.toLowerCase() === 'w') {
        if (state.launcherOpen) return;
        event.preventDefault();
        if (state.selectedTabId) closeTab(state.selectedTabId);
        return;
      }

      if (meta && event.key === ',') {
        event.preventDefault();
        openSettingsPanel();
        return;
      }

      if (state.launcherOpen) return;

      if (meta && event.key.toLowerCase() === 's') {
        event.preventDefault();
        activeView()?.save?.();
        return;
      }

      if (meta && event.key === 'Enter') {
        event.preventDefault();
        activeView()?.send?.();
        return;
      }

      if (meta && event.key.toLowerCase() === 'e') {
        event.preventDefault();
        if (state.selectedTabId) beginRename(state.selectedTabId);
        return;
      }

      if (meta && /^[1-9]$/.test(event.key)) {
        const index = Number(event.key) - 1;
        const tab = state.tabs[index];
        if (tab) {
          event.preventDefault();
          selectTab(tab.id);
        }
        return;
      }

      if (meta && event.key === '0') {
        const tab = state.tabs[state.tabs.length - 1];
        if (tab) {
          event.preventDefault();
          selectTab(tab.id);
        }
        return;
      }

      if (event.ctrlKey && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
        if (!state.tabs.length) return;
        event.preventDefault();
        const index = state.tabs.findIndex((tab) => tab.id === state.selectedTabId);
        const delta = event.key === 'ArrowDown' ? 1 : -1;
        const next = state.tabs[(index + delta + state.tabs.length) % state.tabs.length];
        if (next) selectTab(next.id);
      }
    });
  }

  /* ======================================================================
     侧栏宽度
     ====================================================================== */

  function applySidebarWidth() {
    document.documentElement.style.setProperty('--sidebar-w', `${state.sidebarWidth}px`);
  }

  function initSidebarResize() {
    els.resizer.addEventListener('pointerdown', (event) => {
      event.preventDefault();
      els.resizer.classList.add('is-active');
      document.body.classList.add('is-resizing');
      const startX = event.clientX;
      const startWidth = state.sidebarWidth;

      const move = (moveEvent) => {
        state.sidebarWidth = Math.round(clamp(startWidth + moveEvent.clientX - startX, 168, 340));
        applySidebarWidth();
      };
      const up = () => {
        els.resizer.classList.remove('is-active');
        document.body.classList.remove('is-resizing');
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', up);
        store.touch();
      };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
    });
  }

  /* ======================================================================
     数据导入导出（设置面板复用）
     ====================================================================== */

  async function exportAll() {
    const history = await historyStore.recent(300);
    const payload = {
      kind: 'devkit-web-export',
      version: 1,
      at: Date.now(),
      state,
      history,
    };
    downloadFile(`devkit-session-${new Date().toISOString().slice(0, 10)}.json`, JSON.stringify(payload, null, 2));
    toast('已导出会话数据', 'success', 'download');
  }

  function importAll() {
    const input = h('input', { type: 'file', accept: 'application/json,.json', style: { display: 'none' } });
    document.body.append(input);
    input.addEventListener('change', async () => {
      const file = input.files?.[0];
      input.remove();
      if (!file) return;
      try {
        const text = await file.text();
        const payload = JSON.parse(text);
        const nextState = payload.state ?? payload;
        if (!nextState?.tabs) throw new Error('文件里没有会话数据');
        const ok = await confirmDialog({
          title: '导入会话数据',
          message: '导入会覆盖当前标签、集合与设置，并刷新页面。历史记录会一并恢复。',
          confirmText: '导入并刷新',
        });
        if (!ok) return;
        localStorage.setItem('devkit.web.state.v1', JSON.stringify(nextState));
        if (Array.isArray(payload.history)) {
          await historyStore.bulkPut(payload.history);
        }
        location.reload();
      } catch (error) {
        toast(`导入失败：${error.message}`, 'error', 'alert');
      }
    });
    input.click();
  }

  async function clearAllData() {
    const ok = await confirmDialog({
      title: '清空全部数据',
      message: '将删除所有标签、已保存的请求、历史记录与设置。此操作不可撤销。',
      confirmText: '全部清空',
      danger: true,
    });
    if (!ok) return;
    await historyStore.clear().catch(() => {});
    store.reset();
    location.reload();
  }

  /* ======================================================================
     集合维护（设置面板调用）
     ====================================================================== */

  function detachTabsFromRequests(ids) {
    const set = new Set(ids);
    for (const tab of state.tabs) {
      if (tab.data?.savedRequestId && set.has(tab.data.savedRequestId)) {
        tab.data.savedRequestId = null;
        tab.data.savedFolderId = null;
        tab.data.lastSavedRequest = null;
        views.get(tab.id)?.reloadData?.();
      }
    }
    updateSidebarTitles();
  }

  async function deleteSavedRequest(id) {
    const request = state.httpCollections.requests.find((item) => item.id === id);
    if (!request) return;
    state.httpCollections.requests = state.httpCollections.requests.filter((item) => item.id !== id);
    detachTabsFromRequests([id]);
    historyStore.removeBySavedRequest(id).catch(() => {});
    store.touch();
    renderShell();
  }

  async function deleteFolderDeep(folderId) {
    const collections = state.httpCollections;
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
    const removed = collections.requests.filter((request) => doomed.has(request.folderId));
    collections.requests = collections.requests.filter((request) => !doomed.has(request.folderId));
    collections.folders = collections.folders.filter((folder) => !doomed.has(folder.id));
    detachTabsFromRequests(removed.map((request) => request.id));
    for (const request of removed) {
      historyStore.removeBySavedRequest(request.id).catch(() => {});
    }
    store.touch();
    renderShell();
  }

  /* ======================================================================
     App 对象
     ====================================================================== */

  const app = {
    get state() {
      return store.state;
    },
    persist() {
      store.touch();
    },
    refreshTabTitle() {
      updateSidebarTitles();
    },
    selectTab,
    openTool,
    closeTab,
    showLauncher,
    openSettings: openSettingsPanel,
    applyAppearance,
    applySidebarWidth,
    exportAll,
    importAll,
    clearAllData,
    deleteSavedRequest,
    deleteFolderDeep,
    async proxyStatus() {
      const { checkProxy, proxyStatus } = await import('./tools/http/client.js');
      await checkProxy();
      return proxyStatus;
    },
    get views() {
      return views;
    },
    historyStore,
    reload() {
      renderShell();
    },
  };

  /* ======================================================================
     启动
     ====================================================================== */

  applyAppearance();
  applySidebarWidth();
  const githubLink = document.getElementById('open-github');
  githubLink?.append(icon('github', 15));
  els.settings.append(icon('gear', 15));
  els.settings.title = `设置 (${modKey()},)`;
  els.settings.addEventListener('click', openSettingsPanel);
  els.wake.append(icon('coffee', 15));
  els.wake.title = '防止屏幕休眠';
  els.wake.setAttribute('aria-pressed', String(Boolean(state.wakeLock)));
  els.wake.addEventListener('click', toggleWakeLock);

  const brand = document.querySelector('.sidebar-brand');
  if (brand) {
    brand.style.cursor = 'default';
    brand.title = 'devkit · 新建标签';
    brand.addEventListener('click', showLauncher);
  }

  initSidebarResize();
  initShortcuts();

  store.onChange(() => updateSidebarTitles());

  window.addEventListener('beforeunload', () => store.saveNow());

  // 选中标签先挂载，其余按需挂载
  const selected = activeTab();
  if (selected) ensureMounted(selected);
  renderShell();

  requestAnimationFrame(() => {
    applySidebarWidth();
    applyAppearance();
    views.get(state.selectedTabId)?.resize?.();
  });

  restoreWakeLock();

  return app;
}
