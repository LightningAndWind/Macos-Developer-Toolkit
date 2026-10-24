/* ==========================================================================
   设置面板
   ========================================================================== */

import { h, icon, modKey, formatBytes } from './ui/dom.js';
import { openModal, toast, confirmDialog, promptDialog } from './ui/overlay.js';
import { store, folderOptions } from './store.js';
import { TOOLS } from './tools/registry.js';

const SECTIONS = [
  { id: 'general', label: '通用', icon: 'gear' },
  { id: 'http', label: 'HTTP 请求', icon: 'arrows' },
  { id: 'collections', label: '请求集合', icon: 'folder' },
  { id: 'data', label: '数据', icon: 'database' },
  { id: 'about', label: '关于', icon: 'info' },
];

const REPO_URL = 'https://github.com/LightningAndWind/Macos-Developer-Toolkit';

const SHORTCUTS = [
  ['新建标签', ['⌘', 'T']],
  ['关闭标签', ['⌘', 'W']],
  ['切换标签', ['⌘', '1-9']],
  ['上一个 / 下一个', ['⌃', '↑ ↓']],
  ['重命名标签', ['⌘', 'E']],
  ['保存请求', ['⌘', 'S']],
  ['发送请求', ['⌘', '↵']],
  ['设置', ['⌘', ',']],
];

export function openSettings(app) {
  let active = 'general';
  let proxy = { available: false, checked: false };

  const nav = h('div', { class: 'settings-nav' });
  const panel = h('div', { class: 'settings-panel' });

  const navButtons = new Map();
  for (const section of SECTIONS) {
    const button = h(
      'button',
      {
        onclick: () => {
          active = section.id;
          renderNav();
          renderPanel();
        },
      },
      icon(section.icon, 14),
      section.label
    );
    navButtons.set(section.id, button);
    nav.append(button);
  }

  function renderNav() {
    for (const [id, button] of navButtons) {
      button.setAttribute('aria-selected', String(id === active));
    }
  }

  const modal = openModal({
    title: '设置',
    width: 700,
    className: 'settings-modal',
    body: h('div', { class: 'settings-body' }, nav, panel),
    onClose: () => {},
  });

  function row(name, desc, control) {
    return h(
      'div',
      { class: 'setting-row' },
      h('div', { class: 'setting-main' }, h('div', { class: 'setting-name' }, name), desc ? h('div', { class: 'setting-desc' }, desc) : null),
      control
    );
  }

  function panelTitle(title, desc) {
    return [h('h3', null, title), desc ? h('p', { class: 'section-desc' }, desc) : null].filter(Boolean);
  }

  function segmented(options, current, onSelect) {
    return h(
      'div',
      { class: 'segmented' },
      options.map(({ value, label }) =>
        h(
          'button',
          {
            'aria-selected': String(value === current),
            onclick: () => onSelect(value),
          },
          label
        )
      )
    );
  }

  function renderGeneral() {
    panel.replaceChildren(
      ...panelTitle('通用', '外观、布局与快捷键。'),
      row(
        '外观',
        '跟随系统会在浅色 / 深色之间自动切换。',
        segmented(
          [
            { value: 'system', label: '跟随系统' },
            { value: 'light', label: '浅色' },
            { value: 'dark', label: '深色' },
          ],
          store.state.appearance,
          (value) => {
            store.state.appearance = value;
            store.touch();
            app.applyAppearance();
            renderPanel();
          }
        )
      ),
      row(
        '侧栏宽度',
        `${Math.round(store.state.sidebarWidth)} px · 也可以直接拖拽侧栏右缘`,
        h(
          'button',
          {
            class: 'btn sm',
            onclick: () => {
              store.state.sidebarWidth = 208;
              store.touch();
              app.applySidebarWidth();
              renderPanel();
            },
          },
          '恢复默认'
        )
      ),
      row(
        '防休眠',
        '开启后持有屏幕唤醒锁，避免长时间调试时息屏。入口在侧栏左下角的咖啡杯。',
        h('span', { class: 'setting-value' }, '侧栏左下角切换')
      ),
      h('div', { style: { marginTop: '18px' } }, h('h3', null, '快捷键')),
      h(
        'div',
        { class: 'shortcut-grid', style: { marginTop: '10px' } },
        SHORTCUTS.map(([label, keys]) =>
          h(
            'div',
            { class: 'shortcut-line' },
            h(
              'span',
              { class: 'keys' },
              keys.map((key) => h('span', { class: 'kbd' }, key === '⌘' ? modKey() : key))
            ),
            h('span', null, label)
          )
        )
      )
    );
  }

  async function refreshProxy() {
    proxy = await app.proxyStatus();
    if (active === 'http') renderPanel();
  }

  function proxyCard(value, title, desc, available) {
    return h(
      'div',
      {
        class: 'radio-card',
        role: 'radio',
        'aria-checked': String(store.state.proxyMode === value),
        onclick: () => {
          store.state.proxyMode = value;
          store.touch();
          renderPanel();
        },
      },
      h('span', { class: 'radio-dot' }),
      h(
        'div',
        { class: 'radio-body' },
        h(
          'div',
          { class: 'radio-title' },
          title,
          value === 'direct'
            ? null
            : h(
                'span',
                { class: `status-pill ${available ? 'ok' : value === 'auto' ? '' : 'warn'}`.trim() },
                available ? '代理已连接' : value === 'auto' ? '将使用直连' : '代理未运行'
              )
        ),
        h('div', { class: 'radio-desc' }, desc)
      )
    );
  }

  function renderHTTP() {
    const requestCount = store.state.httpCollections.requests.length;
    panel.replaceChildren(
      ...panelTitle('HTTP 请求', '浏览器直连受同源策略限制；本地代理可发送任意请求并读取完整响应头。'),
      h(
        'div',
        { class: 'radio-cards' },
        proxyCard(
          'auto',
          '自动（推荐）',
          '检测到本地代理时走代理（无 CORS 限制、响应头完整）；否则退回浏览器直连。',
          proxy.available
        ),
        proxyCard('direct', '仅浏览器直连', '纯前端 fetch，不依赖服务端。跨域请求需要目标接口返回 CORS 头。', proxy.available),
        proxyCard('proxy', '仅本地代理', '通过 node server.js 启动的同源服务转发。可以设置任意请求头，支持自签证书以外的普通接口。', proxy.available)
      ),
      h(
        'div',
        { class: 'field-row', style: { marginTop: '10px', gap: '8px' } },
        h(
          'button',
          { class: 'btn sm', onclick: refreshProxy },
          icon('refresh', 12),
          '重新检测代理'
        ),
        h(
          'span',
          { class: 'field-hint' },
          proxy.checked
            ? proxy.available
              ? '代理服务运行中（/api/proxy）'
              : '未检测到代理。运行 node server.js 后点此重试。'
            : '尚未检测'
        )
      ),
      h('div', { style: { marginTop: '18px' } }),
      row(
        '已保存的请求',
        '集合中的请求保存在本机浏览器存储，不会上传。',
        h('span', { class: 'setting-value' }, `${requestCount} 条`)
      ),
      row(
        'HTTP 历史',
        '包含请求与响应快照（响应体最多保留 256 KB / 条）。',
        h(
          'button',
          {
            class: 'btn sm danger',
            onclick: async () => {
              const ok = await confirmDialog({
                title: '清空 HTTP 历史',
                message: '将删除全部历史记录，此操作不可撤销。',
                confirmText: '清空',
                danger: true,
              });
              if (!ok) return;
              await app.historyStore.clear();
              toast('HTTP 历史已清空', 'success', 'check');
            },
          },
          '清空历史'
        )
      )
    );
  }

  function renderCollections() {
    const collections = store.state.httpCollections;
    const total = collections.requests.length;
    const folders = collections.folders;

    const list = h('div', { class: 'collection-manage' });

    const moveRequest = (record) => {
      const select = h('select', { class: 'input' });
      for (const option of folderOptions(store.state)) {
        select.append(
          h(
            'option',
            { value: option.id ?? '', selected: (record.folderId ?? null) === option.id },
            `${'　'.repeat(option.depth)}${option.label}`
          )
        );
      }
      let modal;
      const move = () => {
        record.folderId = select.value || null;
        record.updatedAt = Date.now();
        for (const tab of store.state.tabs) {
          if (tab.data?.savedRequestId === record.id) tab.data.savedFolderId = record.folderId;
        }
        store.touch();
        app.reload();
        renderCollections();
        modal.close();
      };
      modal = openModal({
        title: '移动到文件夹',
        width: 380,
        body: h(
          'div',
          null,
          h('div', { class: 'field', style: { marginBottom: '0' } }, h('label', null, '目标文件夹'), select),
          h('div', { class: 'field-hint', style: { marginTop: '8px' } }, `当前请求：${record.name}`)
        ),
        footer: [
          h('div', { class: 'spacer' }),
          h('button', { class: 'btn', onclick: () => modal.close() }, '取消'),
          h('button', { class: 'btn primary', onclick: move }, '移动'),
        ],
      });
    };

    const requestRow = (record, depth) =>
      h(
        'div',
        { class: 'cm-row', style: { paddingLeft: `${10 + depth * 16}px` } },
        h('span', { class: 'cm-method', style: { color: 'var(--text-3)' } }, record.request.method),
        h('span', { class: 'cm-name', title: record.name }, record.name),
        h('span', { class: 'cm-url', title: record.request.urlString }, record.request.urlString),
        h(
          'button',
          {
            class: 'cm-action',
            title: '重命名',
            onclick: async () => {
              const name = await promptDialog({ title: '重命名请求', label: '名称', value: record.name });
              if (!name) return;
              record.name = name;
              record.updatedAt = Date.now();
              store.touch();
              app.reload();
              renderCollections();
            },
          },
          icon('keyboard', 12)
        ),
        h(
          'button',
          {
            class: 'cm-action',
            title: '移动到文件夹',
            onclick: () => moveRequest(record),
          },
          icon('folder', 12)
        ),
        h(
          'button',
          {
            class: 'cm-action danger',
            title: '删除请求',
            onclick: async () => {
              const ok = await confirmDialog({
                title: '删除已保存的请求',
                message: `将删除「${record.name}」及其历史记录；已打开的相关标签会解绑。`,
                confirmText: '删除',
                danger: true,
              });
              if (!ok) return;
              await app.deleteSavedRequest(record.id);
              renderCollections();
            },
          },
          icon('trash', 12)
        )
      );

    if (!total && !folders.length) {
      list.append(
        h(
          'div',
          { class: 'empty', style: { minHeight: '140px' } },
          h('div', { class: 'empty-icon' }, icon('folder', 26)),
          h('div', { class: 'empty-title' }, '还没有已保存的请求'),
          h('div', { class: 'empty-desc' }, '在 HTTP 标签里填写请求后按 ⌘S，即可保存到集合。')
        )
      );
    }

    for (const record of collections.requests.filter((item) => !item.folderId)) {
      list.append(requestRow(record, 0));
    }

    const walk = (parentId, depth) => {
      for (const folder of folders.filter((item) => (item.parentId ?? null) === parentId)) {
        const children = collections.requests.filter((item) => item.folderId === folder.id);
        list.append(
          h(
            'div',
            { class: 'cm-folder', style: { paddingLeft: `${10 + depth * 16}px` } },
            icon('folder', 12),
            h('span', { class: 'cm-name' }, folder.name),
            h('span', { class: 'group-count' }, String(children.length)),
            h(
              'button',
              {
                class: 'cm-action',
                title: '重命名文件夹',
                onclick: async () => {
                  const name = await promptDialog({ title: '重命名文件夹', label: '名称', value: folder.name });
                  if (!name) return;
                  folder.name = name;
                  store.touch();
                  app.reload();
                  renderCollections();
                },
              },
              icon('keyboard', 12)
            ),
            h(
              'button',
              {
                class: 'cm-action danger',
                title: '删除文件夹',
                onclick: async () => {
                  const count = collections.requests.filter((item) => item.folderId === folder.id).length;
                  const ok = await confirmDialog({
                    title: '删除文件夹',
                    message: `将删除「${folder.name}」及其子文件夹、其中的 ${count} 条请求与对应历史。`,
                    confirmText: '删除',
                    danger: true,
                  });
                  if (!ok) return;
                  await app.deleteFolderDeep(folder.id);
                  renderCollections();
                },
              },
              icon('trash', 12)
            )
          )
        );
        for (const record of children) {
          list.append(requestRow(record, depth + 1));
        }
        walk(folder.id, depth + 1);
      }
    };
    walk(null, 0);

    panel.replaceChildren(
      ...panelTitle('请求集合', '按文件夹管理已保存的请求。删除会同步解绑打开中的标签，并清理对应历史。'),
      h(
        'div',
        { class: 'field-row', style: { marginBottom: '12px' } },
        h('span', { class: 'setting-value' }, `${total} 条请求 · ${folders.length} 个文件夹`),
        h('div', { class: 'spacer' }),
        h(
          'button',
          {
            class: 'btn sm',
            onclick: async () => {
              const name = await promptDialog({ title: '新建文件夹', label: '名称', value: '' });
              if (!name) return;
              store.state.httpCollections.folders.push({ id: `folder_${Date.now().toString(36)}`, name, parentId: null });
              store.touch();
              renderCollections();
            },
          },
          icon('folderPlus', 12),
          '新建文件夹'
        )
      ),
      list
    );
  }

  async function renderData() {
    if (active !== 'data') return;
    const requestCount = store.state.httpCollections.requests.length;
    const folderCount = store.state.httpCollections.folders.length;
    let historyCount = 0;
    try {
      historyCount = await app.historyStore.count();
    } catch {
      historyCount = 0;
    }
    let usage = '';
    try {
      const estimate = await navigator.storage?.estimate?.();
      if (estimate?.usage) usage = formatBytes(estimate.usage);
    } catch {
      usage = '';
    }
    if (active !== 'data') return;

    panel.replaceChildren(
      ...panelTitle('数据', '所有数据都保存在当前浏览器；换浏览器或清理站点数据后会丢失。'),
      h(
        'div',
        { class: 'kv-list' },
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, '标签'), h('span', { class: 'v' }, `${store.state.tabs.length} 个`)),
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, '已保存请求'), h('span', { class: 'v' }, `${requestCount} 条 / ${folderCount} 个文件夹`)),
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, 'HTTP 历史'), h('span', { class: 'v' }, `${historyCount} 条`)),
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, '本地占用'), h('span', { class: 'v' }, usage || '未知')),
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, '存储位置'), h('span', { class: 'v' }, 'localStorage + IndexedDB'))
      ),
      h(
        'div',
        { class: 'field-row', style: { marginTop: '18px', gap: '8px' } },
        h('button', { class: 'btn', onclick: () => app.exportAll() }, icon('download', 13), '导出会话'),
        h('button', { class: 'btn', onclick: () => app.importAll() }, icon('upload', 13), '导入'),
        h('div', { class: 'spacer' }),
        h('button', { class: 'btn danger', onclick: () => app.clearAllData() }, icon('trash', 13), '清空全部')
      ),
      h(
        'div',
        { class: 'hint-line', style: { marginTop: '14px' } },
        '导出文件包含标签、请求集合、设置与最近 300 条 HTTP 历史，可用于迁移或备份。'
      )
    );
  }

  function renderAbout() {
    panel.replaceChildren(
      h(
        'div',
        { style: { display: 'flex', alignItems: 'center', gap: '13px', marginBottom: '16px' } },
        h('img', { src: './assets/appicon.png', alt: '', style: { width: '46px', height: '46px', borderRadius: '11px', boxShadow: '0 0 0 .5px rgba(0,0,0,.14)' } }),
        h(
          'div',
          null,
          h(
            'div',
            { style: { fontSize: '15px', fontWeight: '650', display: 'flex', alignItems: 'center', gap: '7px' } },
            'devkit',
            h('span', { class: 'desk-badge' }, '开源')
          ),
          h('div', { class: 'field-hint' }, 'Web 版 · 1.0.0')
        )
      ),
      h(
        'p',
        { class: 'section-desc' },
        '面向开发者的轻量工具集。一个标签承载一个工具实例，可并行工作。'
      ),
      h(
        'div',
        { class: 'kv-list' },
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, '内置工具'), h('span', { class: 'v' }, TOOLS.filter((t) => !t.desktopOnly).map((t) => t.title).join(' · '))),
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, '网页版'), h('span', { class: 'v' }, 'HTML · CSS · 原生 ES Modules')),
        h('div', { class: 'kv-line' }, h('span', { class: 'k' }, '桌面版'), h('span', { class: 'v' }, 'SwiftUI · SwiftNIO · SQLite'))
      ),
      h(
        'div',
        { class: 'repo-card' },
        h('span', { class: 'repo-icon' }, icon('github', 20)),
        h(
          'div',
          { class: 'repo-info' },
          h(
            'div',
            { class: 'repo-top' },
            h('div', { class: 'repo-name' }, 'LightningAndWind / Macos-Developer-Toolkit'),
            h(
              'a',
              {
                class: 'btn sm repo-open',
                href: REPO_URL,
                target: '_blank',
                rel: 'noopener noreferrer',
              },
              icon('external', 12),
              '打开'
            )
          ),
          h(
            'a',
            {
              class: 'repo-url',
              href: REPO_URL,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            REPO_URL
          )
        )
      ),
      h(
        'div',
        { class: 'desk-note', style: { marginTop: '14px' } },
        icon('info', 15),
        h(
          'div',
          { class: 'desk-note-body' },
          h('strong', null, '浏览器能力的边界'),
          h(
            'div',
            { style: { marginTop: '4px' } },
            'SSH / SFTP / Git 需要本机 shell、文件系统与密钥存储，网页无法提供，因此保留在 macOS 客户端。HTTP 的跨域限制可通过本地代理解决，脚本为同目录的 server.js。'
          )
        )
      )
    );
  }

  function renderPanel() {
    if (active === 'general') renderGeneral();
    else if (active === 'http') renderHTTP();
    else if (active === 'collections') renderCollections();
    else if (active === 'data') renderData();
    else renderAbout();
  }

  renderNav();
  renderPanel();
  refreshProxy();

  return modal;
}
