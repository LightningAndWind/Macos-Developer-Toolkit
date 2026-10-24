/* ==========================================================================
   JSON 工具视图：文本 / 树形双视图 + 格式化 / 压缩 / 排序 + 统计
   ========================================================================== */

import { h, icon, copyText, debounce } from '../../ui/dom.js';
import { openMenu, toast, flashButton } from '../../ui/overlay.js';
import {
  INDENTS,
  parseJSON,
  prettyJSON,
  minifyJSON,
  jsonStats,
  sortKeys,
  scalarDisplay,
  childCount,
} from './parser.js';
import { highlightJSON, plainHighlight } from './highlight.js';

const SAMPLE = `{
  "name": "devkit",
  "version": "1.0.0",
  "description": "面向开发者的轻量工具集",
  "homepage": "https://example.com/devkit",
  "tools": [
    { "id": "http", "title": "HTTP 请求", "network": true },
    { "id": "json", "title": "JSON 工具", "network": false }
  ],
  "stats": {
    "stars": 1280,
    "issues": null,
    "tags": ["macos", "web", "developer-tools"]
  }
}`;

const MAX_HIGHLIGHT_CHARS = 300_000;

export function createJSONView(tab, app) {
  const data = tab.data;
  if (typeof data.text !== 'string') data.text = '';
  if (!data.mode) data.mode = 'code';
  if (!data.indent || !INDENTS[data.indent]) data.indent = 'spaces2';

  const state = {
    parsed: null,
    error: null,
    selectedPath: null,
    selectedValue: null,
    expanded: new Set(),
  };

  let lastGutterLines = -1;
  let highlightFrame = 0;

  /* — 工具栏 — */

  const segCode = h('button', { role: 'tab' }, '文本');
  const segTree = h('button', { role: 'tab' }, '树形');
  const segmented = h('div', { class: 'segmented', role: 'tablist' }, segCode, segTree);

  const indentBtn = h(
    'button',
    {
      class: 'tb-btn',
      onclick: () => {
        openMenu(
          indentBtn,
          Object.entries(INDENTS).map(([key, option]) => ({
            label: option.label,
            checked: data.indent === key,
            run: () => {
              data.indent = key;
              indentLabel.textContent = `缩进 ${option.label}`;
              app.persist();
              toast(`缩进：${option.label}`, '', 'indent');
            },
          }))
        );
      },
    },
    icon('indent', 14),
    null
  );
  const indentLabel = h('span', { class: 'indent-label' }, `缩进 ${INDENTS[data.indent].label}`);
  indentBtn.append(indentLabel);

  const formatBtn = h(
    'button',
    {
      class: 'tb-btn',
      title: '格式化（按当前缩进重排）',
      onclick: () => {
        if (!state.parsed) return;
        setText(prettyJSON(state.parsed, data.indent));
        toast('已格式化', 'success', 'check');
      },
    },
    icon('format', 14),
    h('span', null, '格式化')
  );

  const minifyBtn = h(
    'button',
    {
      class: 'tb-btn',
      title: '压缩为单行',
      onclick: () => {
        if (!state.parsed) return;
        setText(minifyJSON(state.parsed));
        toast('已压缩', 'success', 'check');
      },
    },
    icon('compress', 14),
    h('span', null, '压缩')
  );

  const sortBtn = h(
    'button',
    {
      class: 'tb-btn',
      title: '按键名排序',
      onclick: () => {
        if (!state.parsed) return;
        openMenu(sortBtn, [
          { heading: '排序键名' },
          { label: '升序（递归）', run: () => applySort(true, true) },
          { label: '降序（递归）', run: () => applySort(false, true) },
          { sep: true },
          { label: '升序（仅顶层）', run: () => applySort(true, false) },
          { label: '降序（仅顶层）', run: () => applySort(false, false) },
        ]);
      },
    },
    icon('sort', 14),
    h('span', null, '排序')
  );

  const copyBtn = h(
    'button',
    {
      class: 'tb-btn',
      title: '复制全部内容',
      onclick: async () => {
        const ok = await copyText(data.text);
        if (ok) flashButton(copyBtn, '复制成功');
        else toast('复制失败', 'error', 'alert');
      },
    },
    icon('copy', 14),
    h('span', null, '复制')
  );

  const toolbar = h(
    'div',
    { class: 'json-toolbar' },
    segmented,
    indentBtn,
    h('div', { class: 'spacer' }),
    formatBtn,
    minifyBtn,
    sortBtn,
    copyBtn
  );

  /* — 编辑器 — */

  const gutter = h('div', { class: 'code-gutter' });
  const highlighted = h('pre', { class: 'code' });
  const layer = h('div', { class: 'code-layer' }, highlighted);
  const textarea = h('textarea', {
    class: 'code-input',
    spellcheck: 'false',
    autocomplete: 'off',
    autocapitalize: 'off',
    placeholder: '',
    'aria-label': 'JSON 文本',
  });
  textarea.value = data.text;
  const canvas = h('div', { class: 'code-canvas' }, layer, textarea);
  const editor = h('div', { class: 'code-editor' }, gutter, canvas);

  const tree = h('div', { class: 'json-tree hidden' });

  const placeholder = h(
    'div',
    { class: 'json-placeholder show' },
    h(
      'div',
      { class: 'empty' },
      h('div', { class: 'empty-icon' }, icon('braces', 30)),
      h('div', { class: 'empty-title' }, '在此粘贴 JSON'),
      h('div', { class: 'empty-desc' }, '支持校验、格式化、键排序与树形浏览。也可以先载入一段示例。'),
      h(
        'button',
        { class: 'btn sm', onclick: () => setText(SAMPLE) },
        icon('braces', 13),
        '载入示例'
      )
    )
  );

  const content = h('div', { class: 'json-content' }, editor, tree, placeholder);

  /* — 状态栏 — */

  const status = h('div', { class: 'status-bar' });

  const root = h('div', { class: 'tool json-tool' }, toolbar, content, status);

  /* — 状态渲染 — */

  function renderSegmented() {
    segCode.setAttribute('aria-selected', String(data.mode === 'code'));
    segTree.setAttribute('aria-selected', String(data.mode === 'tree'));
  }

  function renderMode() {
    renderSegmented();
    const isCode = data.mode === 'code';
    editor.classList.toggle('hidden', !isCode);
    tree.classList.toggle('hidden', isCode);
    placeholder.classList.toggle('show', isCode && !data.text.trim());
    if (!isCode) renderTree();
  }

  function typeBreakdown(stats) {
    const parts = [];
    if (stats.objectCount) parts.push(`对象 ${stats.objectCount}`);
    if (stats.arrayCount) parts.push(`数组 ${stats.arrayCount}`);
    if (stats.stringCount) parts.push(`字符串 ${stats.stringCount}`);
    if (stats.numberCount) parts.push(`数字 ${stats.numberCount}`);
    if (stats.boolCount) parts.push(`布尔 ${stats.boolCount}`);
    if (stats.nullCount) parts.push(`空 ${stats.nullCount}`);
    return parts.join(' · ');
  }

  function renderStatus() {
    status.replaceChildren();
    const lines = data.text ? data.text.split('\n').length : 0;
    const chars = data.text.length;

    if (!data.text.trim()) {
      status.append(h('span', { class: 'sb-item' }, icon('braces', 12), '等待输入 JSON'));
    } else if (state.error) {
      status.append(
        h(
          'span',
          { class: 'sb-item sb-error', title: state.error.displayText },
          icon('alert', 12),
          state.error.displayText
        )
      );
    } else if (state.parsed) {
      const stats = state.stats ?? jsonStats(state.parsed);
      status.append(
        h('span', { class: 'sb-item sb-ok' }, icon('checkCircle', 12), '有效 JSON'),
        h('span', { class: 'sb-item' }, `节点 ${stats.nodeCount}`),
        h('span', { class: 'sb-item' }, `深度 ${stats.maxDepth}`),
        h('span', { class: 'sb-item' }, typeBreakdown(stats))
      );
    }

    if (state.selectedPath && data.mode === 'tree') {
      status.append(h('span', { class: 'sb-item sb-path', title: state.selectedPath }, state.selectedPath));
    }

    status.append(h('span', { class: 'sb-tail' }, `${chars} 字符 · ${lines} 行`));

    const valid = Boolean(state.parsed);
    formatBtn.disabled = !valid;
    minifyBtn.disabled = !valid;
    sortBtn.disabled = !valid;
    copyBtn.disabled = !data.text;
  }

  function renderGutter() {
    const lines = data.text ? data.text.split('\n').length : 1;
    if (lines === lastGutterLines) return;
    lastGutterLines = lines;
    let html = '';
    for (let i = 1; i <= lines; i += 1) html += `<div class="ln">${i}</div>`;
    gutter.innerHTML = html;
    gutter.scrollTop = textarea.scrollTop;
  }

  function renderHighlight() {
    if (data.text.length > MAX_HIGHLIGHT_CHARS) {
      highlighted.innerHTML = plainHighlight(data.text);
      return;
    }
    highlighted.innerHTML = highlightJSON(data.text);
  }

  function scheduleHighlight() {
    if (highlightFrame) return;
    highlightFrame = requestAnimationFrame(() => {
      highlightFrame = 0;
      renderHighlight();
      syncScroll();
    });
  }

  function syncScroll() {
    highlighted.style.transform = `translate(${-textarea.scrollLeft}px, ${-textarea.scrollTop}px)`;
    gutter.scrollTop = textarea.scrollTop;
  }

  const refresh = debounce(() => {
    const result = parseJSON(data.text);
    if (result.ok) {
      state.error = null;
      state.parsed = result.value;
      state.stats = jsonStats(result.value);
      seedExpanded(result.value, '$', 0);
    } else {
      state.error = result.error;
      state.parsed = null;
      state.stats = null;
    }
    if (!data.text.trim()) {
      state.error = null;
      state.parsed = null;
      state.stats = null;
    }
    renderStatus();
    if (data.mode === 'tree') renderTree();
  }, 90);

  function setText(text) {
    data.text = text;
    textarea.value = text;
    renderGutter();
    renderHighlight();
    refresh();
    refresh.flush();
    renderStatus();
    placeholder.classList.toggle('show', !text.trim());
    app.persist();
    app.refreshTabTitle?.(tab.id);
  }

  /* — 树形 — */

  function seedExpanded(value, path, depth) {
    if (depth > 2) return;
    if (value.type !== 'object' && value.type !== 'array') return;
    state.expanded.add(path);
    if (value.type === 'object') {
      for (const member of value.members) {
        seedExpanded(member.value, childPath(path, member.key, false), depth + 1);
      }
    } else {
      value.values.forEach((item, index) =>
        seedExpanded(item, childPath(path, index, true), depth + 1)
      );
    }
  }

  function childPath(parentPath, key, isIndex) {
    if (isIndex) return `${parentPath}[${key}]`;
    if (/^[A-Za-z_$][\w$]*$/.test(key)) return `${parentPath}.${key}`;
    return `${parentPath}[${JSON.stringify(key)}]`;
  }

  function renderTree() {
    tree.replaceChildren();
    if (!state.parsed) {
      tree.append(
        h(
          'div',
          { class: 'empty', style: { paddingTop: '60px' } },
          h('div', { class: 'empty-icon' }, icon('tree', 28)),
          h('div', { class: 'empty-title' }, '无法构建树'),
          h('div', { class: 'empty-desc' }, state.error?.displayText ?? '请输入合法的 JSON 后再查看树形视图。')
        )
      );
      return;
    }

    const rows = h('div');
    const walk = (value, path, key, depth, isIndex) => {      const row = h('div', {
        class: `tree-row ${state.selectedPath === path ? 'is-selected' : ''}`.trim(),
        dataset: { path },
      });
      row.append(h('span', { class: 'tree-indent', style: { width: `${depth * 16}px` } }));

      const isContainer = value.type === 'object' || value.type === 'array';
      const count = childCount(value);
      const expanded = state.expanded.has(path);
      const toggle = h('button', {
        class: `tree-toggle ${isContainer && count ? '' : 'empty'}`.trim(),
        title: expanded ? '折叠' : '展开',
        onclick: (event) => {
          event.stopPropagation();
          if (!isContainer || !count) return;
          if (expanded) state.expanded.delete(path);
          else state.expanded.add(path);
          renderTree();
        },
      });
      if (isContainer && count) toggle.append(icon(expanded ? 'chevronDown' : 'chevronRight', 12));
      row.append(toggle);

      if (key !== null) {
        if (isIndex) {
          row.append(h('span', { class: 'tree-key' }, String(key)));
        } else {
          row.append(h('span', { class: 'tree-key' }, `"${key}"`));
        }
        row.append(h('span', { class: 'tree-colon' }, ': '));
      }

      if (isContainer) {
        const open = value.type === 'object' ? '{' : '[';
        const close = value.type === 'object' ? '}' : ']';
        row.append(
          h('span', { class: 'tree-brace' }, `${open}${expanded ? '' : '…'}${expanded ? '' : close}`),
          h('span', { class: 'tree-child-count' }, String(count))
        );
      } else {
        const cls =
          value.type === 'string'
            ? 'tree-val-str'
            : value.type === 'number'
              ? 'tree-val-num'
              : value.type === 'bool' || value.type === 'null'
                ? 'tree-val-lit'
                : 'tree-val-punc';
        const display = scalarDisplay(value);
        const text = display.length > 240 ? `${display.slice(0, 240)}…` : display;
        row.append(h('span', { class: cls, title: display }, text));
      }

      const copy = h(
        'button',
        {
          class: 'tree-copy',
          title: '复制此子树',
          onclick: async (event) => {
            event.stopPropagation();
            const ok = await copyText(prettyJSON(value, data.indent));
            toast(ok ? '已复制子树' : '复制失败', ok ? 'success' : 'error', ok ? 'check' : 'alert');
          },
        },
        icon('copy', 12)
      );
      row.append(copy);

      row.addEventListener('click', () => {
        state.selectedPath = path;
        state.selectedValue = value;
        for (const el of tree.querySelectorAll('.tree-row.is-selected')) el.classList.remove('is-selected');
        row.classList.add('is-selected');
        renderStatus();
      });

      rows.append(row);

      if (isContainer && expanded) {
        if (value.type === 'object') {
          for (const member of value.members) {
            walk(member.value, childPath(path, member.key, false), member.key, depth + 1, false);
          }
        } else {
          value.values.forEach((item, index) => {
            walk(item, childPath(path, index, true), index, depth + 1, true);
          });
        }
      }
    };

    walk(state.parsed, '$', null, 0, false);
    tree.append(rows);
  }

  /* — 行为 — */

  function applySort(ascending, recursive) {
    if (!state.parsed) return;
    const sorted = sortKeys(state.parsed, ascending, recursive);
    setText(prettyJSON(sorted, data.indent));
    toast('已按键名排序', 'success', 'check');
  }

  segCode.addEventListener('click', () => {
    data.mode = 'code';
    app.persist();
    renderMode();
    renderStatus();
    textarea.focus();
  });

  segTree.addEventListener('click', () => {
    data.mode = 'tree';
    app.persist();
    renderMode();
    renderStatus();
  });

  /* 文本编辑 */

  const unit = () => INDENTS[data.indent].unit;

  textarea.addEventListener('input', () => {
    data.text = textarea.value;
    renderGutter();
    scheduleHighlight();
    refresh();
    placeholder.classList.toggle('show', !data.text.trim());
    app.persist();
  });

  textarea.addEventListener('scroll', syncScroll, { passive: true });

  textarea.addEventListener('keydown', (event) => {
    const { selectionStart: start, selectionEnd: end, value } = textarea;

    if (event.key === 'Tab') {
      event.preventDefault();
      const indentUnit = unit();
      if (start !== end) {
        // 多行缩进 / 反缩进
        const lineStart = value.lastIndexOf('\n', start - 1) + 1;
        const block = value.slice(lineStart, end);
        const lines = block.split('\n');
        const changed = event.shiftKey
          ? lines.map((line) => (line.startsWith(indentUnit) ? line.slice(indentUnit.length) : line.replace(/^\t|^ {1,4}/, '')))
          : lines.map((line) => indentUnit + line);
        const replacement = changed.join('\n');
        textarea.setRangeText(replacement, lineStart, end, 'select');
      } else if (event.shiftKey) {
        const lineStart = value.lastIndexOf('\n', start - 1) + 1;
        const line = value.slice(lineStart, start);
        const match = line.match(/(\t| {1,4})$/);
        if (match) {
          textarea.setRangeText('', start - match[1].length, end, 'end');
        }
      } else {
        textarea.setRangeText(indentUnit, start, end, 'end');
      }
      textarea.dispatchEvent(new Event('input'));
      return;
    }

    if (event.key === 'Enter') {
      event.preventDefault();
      const lineStart = value.lastIndexOf('\n', start - 1) + 1;
      const line = value.slice(lineStart, start);
      const leading = (line.match(/^\s*/) || [''])[0];
      const prevChar = value[start - 1];
      const nextChar = value[end];

      let insert = `\n${leading}`;
      if (prevChar === '{' || prevChar === '[') insert += unit();
      if ((prevChar === '{' || prevChar === '[') && (nextChar === '}' || nextChar === ']')) {
        insert += `\n${leading}`;
        textarea.setRangeText(insert, start, end, 'start');
        textarea.selectionStart = textarea.selectionEnd = start + 1 + leading.length + unit().length;
      } else {
        textarea.setRangeText(insert, start, end, 'end');
      }
      textarea.dispatchEvent(new Event('input'));
      return;
    }

    const pairs = { '"': '"', '{': '}', '[': ']' };
    const closers = new Set(['"', '}', ']']);
    if (start === end) {
      const nextChar = value[start] ?? '';
      // 只有「闭合字符」才跳过已有的同名闭合符；输入 `{` 后面跟着 `}` 时应补成 `{}`。
      if (closers.has(event.key) && nextChar === event.key) {
        event.preventDefault();
        textarea.selectionStart = textarea.selectionEnd = start + 1;
        return;
      }
      if (pairs[event.key] && (!nextChar || /[\s,}\]:]/.test(nextChar))) {
        event.preventDefault();
        textarea.setRangeText(event.key + pairs[event.key], start, end, 'end');
        textarea.selectionStart = textarea.selectionEnd = start + 1;
        textarea.dispatchEvent(new Event('input'));
        return;
      }
    }

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {
      event.preventDefault();
      toast('JSON 内容随会话自动保存，无需手动保存', '', 'info');
    }
  });

  /* 全局粘贴：空编辑器时自动接管剪贴板里的 JSON */
  textarea.addEventListener('paste', () => {
    setTimeout(() => {
      data.text = textarea.value;
      renderGutter();
      renderHighlight();
      refresh();
    });
  });

  /* 初始化 */

  renderMode();
  renderGutter();
  renderHighlight();
  refresh();
  refresh.flush();
  renderStatus();
  syncScroll();

  if (data.mode === 'tree') renderTree();

  return {
    el: root,
    focus() {
      if (data.mode === 'code') {
        textarea.focus();
        const length = textarea.value.length;
        textarea.setSelectionRange(length, length);
      }
    },
    resize() {
      syncScroll();
    },
    getTitle() {
      return null;
    },
    hasUnsaved() {
      return false;
    },
  };
}
