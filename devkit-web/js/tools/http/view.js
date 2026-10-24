/* ==========================================================================
   HTTP 请求工具视图
   ========================================================================== */

import {
  h,
  icon,
  uid,
  copyText,
  debounce,
  methodColor,
  statusInfo,
  formatBytes,
  formatDuration,
  formatTimeout,
  historyTime,
  fullTime,
} from '../../ui/dom.js';
import { openMenu, openPopover, openModal, toast, flashButton, confirmDialog } from '../../ui/overlay.js';
import { store, folderOptions, createFolder, defaultRequest } from '../../store.js';
import {
  METHOD_PRESETS,
  TIMEOUT_PRESETS,
  MIN_TIMEOUT,
  MAX_TIMEOUT,
  newKV,
  bodyPayload,
  authHeaderValue,
  syncQueryToParams,
  requestIsDirty,
  requestIsEmpty,
  toCurl,
  appliedURLString,
  normalizeRequest,
  buildRequestSpec,
} from './model.js';
import { sendRequest, responseText, decodeBody, proxyStatus, checkProxy } from './client.js';
import { historyStore, base64ToBytes } from './history.js';
import { highlightJSON } from '../json/highlight.js';

const clone = (value) => JSON.parse(JSON.stringify(value));

export function createHTTPView(tab, app) {
  const data = tab.data;
  data.request = normalizeRequest(data.request);
  if (!('savedRequestId' in data)) data.savedRequestId = null;
  if (!('savedFolderId' in data)) data.savedFolderId = null;
  if (!('lastSavedRequest' in data)) data.lastSavedRequest = null;

  const state = {
    section: 'params',
    loading: false,
    response: null,
    error: null,
    cancelled: false,
    history: [],
    historyLoaded: false,
    historyQuery: '',
    controller: null,
    previewUrl: null,
    responseTab: 'pretty',
  };

  /* ======================================================================
     请求栏
     ====================================================================== */

  const methodLabel = h('span', { class: 'method-text' }, data.request.method);
  const methodButton = h(
    'button',
    { class: 'method-picker', title: '请求方法' },
    methodLabel,
    icon('chevronDown', 11, 'method-chevron')
  );
  const customMethodInput = h('input', {
    class: 'input mono',
    style: { display: 'none', width: '86px', height: '30px' },
    spellcheck: 'false',
  });
  const methodWrap = h('div', { style: { display: 'flex', flex: 'none' } }, methodButton, customMethodInput);

  const urlInput = h('input', {
    type: 'text',
    placeholder: 'https://api.example.com/v1/resource',
    spellcheck: 'false',
    autocomplete: 'off',
    autocapitalize: 'off',
    'aria-label': '请求地址',
  });
  urlInput.value = data.request.urlString;

  const urlBox = h('div', { class: 'url-box' }, icon('globe', 14, 'url-icon'), urlInput);

  const timeoutLabel = h('span', { class: 'timeout-chip-label' }, formatTimeout(data.request.timeoutSeconds));
  const timeoutChip = h('button', { class: 'chip-btn', title: '请求超时（空闲超时）' }, icon('clock', 13), timeoutLabel);

  const sendButton = h(
    'button',
    { class: 'send-btn', title: '发送请求 (⌘↵)' },
    icon('send', 13),
    h('span', null, '发送')
  );

  const stopButton = h(
    'button',
    { class: 'send-btn stop hidden', title: '中断在途请求' },
    icon('stop', 12),
    h('span', null, '停止')
  );

  const moreButton = h('button', { class: 'icon-btn', title: '更多' }, icon('more', 16));

  const requestBar = h(
    'div',
    { class: 'request-bar' },
    methodWrap,
    urlBox,
    timeoutChip,
    sendButton,
    stopButton,
    moreButton
  );

  /* ======================================================================
     编辑器（上区）
     ====================================================================== */

  const editorMeta = h('span', { class: 'editor-meta' });
  const saveButton = h('button', { class: 'tb-btn', title: '保存请求 (⌘S)' }, icon('file', 13), h('span', null, '保存'));

  const sectionButtons = new Map();
  const segmented = h('div', { class: 'segmented', role: 'tablist' });
  for (const [key, label] of [
    ['params', 'Params'],
    ['headers', 'Headers'],
    ['body', 'Body'],
    ['auth', 'Auth'],
    ['history', '历史'],
  ]) {
    const button = h('button', { role: 'tab', onclick: () => showSection(key) }, label);
    sectionButtons.set(key, button);
    segmented.append(button);
  }

  const editorTabs = h(
    'div',
    { class: 'editor-tabs' },
    segmented,
    h('div', { class: 'spacer' }),
    editorMeta,
    saveButton
  );

  const panesHost = h('div', { class: 'editor-scroll' });
  const editorPane = h('div', { class: 'http-editor-pane' }, editorTabs, panesHost);

  const panes = {
    params: h('div', { class: 'kv-editor' }),
    headers: h('div', { class: 'kv-editor' }),
    body: h('div', { class: 'pane-pad' }),
    auth: h('div', { class: 'pane-pad' }),
    history: h('div', { class: 'history-pane' }),
  };
  for (const pane of Object.values(panes)) {
    pane.classList.add('hidden');
    panesHost.append(pane);
  }

  /* — KV 编辑器 — */

  function renderKV(
    container,
    items,
    { toggles = false, keyPlaceholder = '键', valuePlaceholder = '值', extraActions = [], emptyHint = '暂无条目' } = {}
  ) {
    container.replaceChildren();

    if (!items.length) {
      container.append(h('div', { class: 'kv-empty' }, emptyHint));
    }

    const rows = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '7px' } });
    const changed = () => {
      app.persist();
      updateMeta();
    };

    items.forEach((item) => {
      const keyInput = h('input', {
        class: 'input kv-key',
        placeholder: keyPlaceholder,
        spellcheck: 'false',
        value: item.key,
      });
      const valueInput = h('input', {
        class: 'input kv-val',
        placeholder: valuePlaceholder,
        spellcheck: 'false',
        value: item.value,
      });
      keyInput.addEventListener('input', () => {
        item.key = keyInput.value;
        changed();
      });
      valueInput.addEventListener('input', () => {
        item.value = valueInput.value;
        changed();
      });

      const row = h(
        'div',
        { class: 'kv-row' },
        toggles
          ? h('input', {
              type: 'checkbox',
              class: 'checkbox',
              checked: item.enabled,
              title: item.enabled ? '已启用' : '已禁用',
              onchange: (event) => {
                item.enabled = event.target.checked;
                changed();
              },
            })
          : null,
        keyInput,
        valueInput,
        h(
          'button',
          {
            class: 'kv-del',
            title: '删除这一行',
            onclick: () => {
              const at = items.findIndex((entry) => entry.id === item.id);
              if (at >= 0) items.splice(at, 1);
              changed();
              renderKV(container, items, { toggles, keyPlaceholder, valuePlaceholder, extraActions });
            },
          },
          icon('minus', 13)
        )
      );
      rows.append(row);
    });
    container.append(rows);

    const addButton = h(
      'button',
      {
        class: 'btn sm',
        onclick: () => {
          items.push(newKV());
          app.persist();
          renderKV(container, items, { toggles, keyPlaceholder, valuePlaceholder, extraActions });
          const inputs = container.querySelectorAll('.kv-key');
          inputs[inputs.length - 1]?.focus();
        },
      },
      icon('plus', 12),
      '添加'
    );

    container.append(h('div', { class: 'kv-actions' }, addButton, ...extraActions));
  }

  /* — Params — */

  const paramsPane = panes.params;
  const paramsEditor = h('div', { class: 'kv-editor' });
  paramsPane.replaceChildren(paramsEditor);

  function renderParams() {
    renderKV(paramsEditor, data.request.params, {
      toggles: true,
      keyPlaceholder: '参数名',
      valuePlaceholder: '参数值',
      emptyHint: '暂无参数。点「添加」新增，或用「从 URL 解析」把地址里的 query 拉进表格。',
      extraActions: [
        h(
          'button',
          {
            class: 'btn sm',
            title: '把 URL 上的 query 拉进表格',
            onclick: () => {
              const added = syncQueryToParams(data.request);
              if (!added) {
                toast('URL 上没有可解析的查询参数', 'warn', 'info');
                return;
              }
              app.persist();
              renderParams();
              toast(`已解析 ${added} 个参数`, 'success', 'check');
            },
          },
          icon('corner', 12),
          '从 URL 解析'
        ),
        h('span', { class: 'hint-line' }, '启用的参数会覆盖 URL 中的同名项'),
      ],
    });
  }

  /* — Headers — */

  const headersEditor = h('div', { class: 'kv-editor' });
  panes.headers.replaceChildren(headersEditor);

  function renderHeaders() {
    renderKV(headersEditor, data.request.headers, {
      toggles: true,
      keyPlaceholder: 'Header',
      valuePlaceholder: '值',
      emptyHint: '暂无自定义请求头。Content-Type 与 Authorization 会按 Body / Auth 分区自动补全。',
    });
  }

  /* — Body — */

  const bodyKind = data.request.body.kind ?? 'none';
  const bodySeg = h('div', { class: 'segmented' });
  const bodyKindButtons = new Map();
  for (const [key, label] of [
    ['none', '无'],
    ['json', 'JSON'],
    ['form', 'Form URL-encoded'],
    ['raw', 'Raw'],
  ]) {
    const button = h('button', { onclick: () => setBodyKind(key) }, label);
    bodyKindButtons.set(key, button);
    bodySeg.append(button);
  }

  const bodyTextarea = h('textarea', {
    class: 'body-editor',
    spellcheck: 'false',
    placeholder: '请求体内容',
  });
  bodyTextarea.value = data.request.body.text ?? '';

  const formatJSONButton = h(
    'button',
    { class: 'btn sm', onclick: () => formatBodyJSON() },
    icon('braces', 12),
    '格式化 JSON'
  );

  const bodyFormHost = h('div', { class: 'kv-editor', style: { padding: '0' } });
  const bodyHost = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '9px', flex: '1' } });
  panes.body.replaceChildren(
    h('div', { class: 'field-row' }, h('span', { class: 'field-label' }, '类型'), bodySeg),
    bodyHost
  );

  function setBodyKind(kind) {
    data.request.body.kind = kind;
    app.persist();
    renderBody();
  }

  function formatBodyJSON() {
    try {
      const parsed = JSON.parse(data.request.body.text);
      data.request.body.text = JSON.stringify(parsed, null, 2);
      bodyTextarea.value = data.request.body.text;
      app.persist();
      toast('已格式化', 'success', 'check');
    } catch (error) {
      toast(`JSON 解析失败：${error.message}`, 'error', 'alert');
    }
  }

  function renderBody() {
    const kind = data.request.body.kind;
    for (const [key, button] of bodyKindButtons) {
      button.setAttribute('aria-selected', String(key === kind));
    }
    bodyHost.replaceChildren();
    if (kind === 'none') {
      bodyHost.append(h('div', { class: 'hint-line' }, '该请求不含 Body。'));
      return;
    }
    if (kind === 'form') {
      renderKV(bodyFormHost, data.request.body.formFields, {
        keyPlaceholder: '字段',
        valuePlaceholder: '值',
      });
      bodyHost.append(bodyFormHost);
      return;
    }
    if (kind === 'json') {
      bodyHost.append(h('div', { class: 'field-row' }, formatJSONButton));
    }
    bodyHost.append(bodyTextarea);
  }

  bodyTextarea.addEventListener('input', () => {
    data.request.body.text = bodyTextarea.value;
    app.persist();
  });

  /* — Auth — */

  const authSeg = h('div', { class: 'segmented' });
  const authKindButtons = new Map();
  for (const [key, label] of [
    ['none', '无'],
    ['bearer', 'Bearer Token'],
    ['basic', 'Basic Auth'],
  ]) {
    const button = h('button', { onclick: () => setAuthKind(key) }, label);
    authKindButtons.set(key, button);
    authSeg.append(button);
  }
  const authFields = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '11px' } });
  const authPreview = h('div', { class: 'auth-preview' });
  panes.auth.replaceChildren(
    h('div', { class: 'field-row' }, h('span', { class: 'field-label' }, '方式'), authSeg),
    authFields,
    authPreview
  );

  function setAuthKind(kind) {
    data.request.auth.kind = kind;
    app.persist();
    renderAuth();
  }

  function renderAuth() {
    const auth = data.request.auth;
    for (const [key, button] of authKindButtons) {
      button.setAttribute('aria-selected', String(key === auth.kind));
    }
    authFields.replaceChildren();
    if (auth.kind === 'none') {
      authFields.append(h('div', { class: 'hint-line' }, '不发送 Authorization 头。'));
    } else if (auth.kind === 'bearer') {
      const input = h('input', { class: 'input mono', placeholder: '访问令牌', value: auth.token });
      input.addEventListener('input', () => {
        auth.token = input.value;
        app.persist();
        renderAuthPreview();
      });
      authFields.append(
        h('div', { class: 'field' }, h('label', null, 'TOKEN'), input)
      );
    } else {
      const user = h('input', { class: 'input', placeholder: 'username', value: auth.username });
      const pass = h('input', { class: 'input', type: 'password', placeholder: 'password', value: auth.password });
      user.addEventListener('input', () => {
        auth.username = user.value;
        app.persist();
        renderAuthPreview();
      });
      pass.addEventListener('input', () => {
        auth.password = pass.value;
        app.persist();
        renderAuthPreview();
      });
      authFields.append(
        h('div', { class: 'field' }, h('label', null, '用户名'), user),
        h('div', { class: 'field' }, h('label', null, '密码'), pass)
      );
    }
    renderAuthPreview();
  }

  function renderAuthPreview() {
    const value = authHeaderValue(data.request.auth);
    authPreview.textContent = value ? `将发送：Authorization: ${value.slice(0, 28)}…` : '';
    authPreview.classList.toggle('hidden', !value);
  }

  /* — 历史 — */

  const historySearch = h('input', {
    type: 'search',
    placeholder: '搜索历史（URL / 方法 / 状态码）',
    spellcheck: 'false',
    'aria-label': '搜索历史',
  });
  const historyList = h('div', { class: 'history-list' });
  const historyClear = h(
    'button',
    { class: 'icon-btn', title: '清空全部历史' },
    icon('trash', 14)
  );
  const historySearchBox = h(
    'div',
    { class: 'history-search', style: { flex: '1' } },
    icon('search', 13),
    historySearch
  );
  panes.history.replaceChildren(
    h('div', { class: 'field-row', style: { flex: 'none' } }, historySearchBox, historyClear),
    historyList
  );

  /* ======================================================================
     响应区（下区）
     ====================================================================== */

  const responsePane = h('div', { class: 'http-response-pane' });
  const divider = h('div', { class: 'h-divider', title: '拖拽调整高度 · 双击恢复 50/50' });
  const split = h('div', { class: 'http-split' }, editorPane, divider, responsePane);

  const root = h('div', { class: 'tool http-tool' }, requestBar, split);

  /* ======================================================================
     请求栏行为
     ====================================================================== */

  function setMethod(method) {
    data.request.method = method;
    methodLabel.textContent = method;
    methodLabel.style.color = methodColor(method);
    app.persist();
  }

  function renderMethod() {
    methodLabel.textContent = data.request.method;
    methodLabel.style.color = methodColor(data.request.method);
    methodButton.classList.toggle('custom', !METHOD_PRESETS.includes(data.request.method));
  }

  methodButton.addEventListener('click', () => {
    const items = METHOD_PRESETS.map((method) => ({
      label: method,
      checked: data.request.method === method,
      icon: 'arrows',
      run: () => setMethod(method),
    }));
    items.push(
      { sep: true },
      {
        label: '自定义…',
        icon: 'keyboard',
        run: () => {
          customMethodInput.value = data.request.method;
          methodButton.style.display = 'none';
          customMethodInput.style.display = 'block';
          customMethodInput.focus();
          customMethodInput.select();
        },
      }
    );
    openMenu(methodButton, items);
  });

  function commitCustomMethod(cancel = false) {
    customMethodInput.style.display = 'none';
    methodButton.style.display = '';
    if (cancel) {
      renderMethod();
      return;
    }
    const value = customMethodInput.value.trim().toUpperCase();
    if (value) setMethod(value);
    else renderMethod();
  }

  customMethodInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      commitCustomMethod();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      commitCustomMethod(true);
    }
  });
  customMethodInput.addEventListener('blur', () => commitCustomMethod());

  urlInput.addEventListener('input', () => {
    data.request.urlString = urlInput.value;
    app.persist();
    scheduleTitleRefresh();
    updateMeta();
    updateSendState();
  });

  urlInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      send();
    }
  });

  const scheduleTitleRefresh = debounce(() => app.refreshTabTitle(tab.id), 320);

  timeoutChip.addEventListener('click', () => {
    const presets = h('div', { class: 'preset-row' });
    const numberInput = h('input', {
      class: 'input',
      type: 'number',
      min: String(MIN_TIMEOUT),
      max: String(MAX_TIMEOUT),
      value: String(data.request.timeoutSeconds),
    });

    const setValue = (seconds) => {
      const clamped = Math.min(MAX_TIMEOUT, Math.max(MIN_TIMEOUT, Math.round(Number(seconds) || 30)));
      data.request.timeoutSeconds = clamped;
      timeoutLabel.textContent = formatTimeout(clamped);
      numberInput.value = String(clamped);
      for (const button of presets.querySelectorAll('button')) {
        button.setAttribute('aria-pressed', String(Number(button.dataset.value) === clamped));
      }
      app.persist();
    };

    for (const seconds of TIMEOUT_PRESETS) {
      const button = h(
        'button',
        {
          class: 'preset-btn',
          dataset: { value: String(seconds) },
          'aria-pressed': String(data.request.timeoutSeconds === seconds),
          onclick: () => setValue(seconds),
        },
        formatTimeout(seconds)
      );
      presets.append(button);
    }

    numberInput.addEventListener('change', () => setValue(numberInput.value));
    numberInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') setValue(numberInput.value);
    });

    const content = h(
      'div',
      { class: 'timeout-pop' },
      h('div', { class: 'tp-title' }, '常用档位'),
      presets,
      h('div', { class: 'tp-title' }, '自定义'),
      h('div', { class: 'custom-timeout' }, numberInput, h('span', { class: 'hint-line' }, '秒')),
      h(
        'div',
        { class: 'tp-note' },
        '空闲超时，不是总时长：每收到一段响应数据就重新计时。流式接口只要相邻两块间隔不超限就不会触发；长耗时接口建议 120 秒以上。'
      )
    );
    openPopover(timeoutChip, content);
  });

  sendButton.addEventListener('click', () => send());
  stopButton.addEventListener('click', () => state.controller?.abort());

  moreButton.addEventListener('click', () => {
    openMenu(
      moreButton,
      [
        { label: '复制为 cURL', icon: 'copy', disabled: requestIsEmpty(data.request), run: copyCurl },
        { label: '另存为…', icon: 'file', disabled: requestIsEmpty(data.request), run: () => openSaveDialog(true) },
        { sep: true },
        {
          label: '清空请求',
          icon: 'trash',
          danger: true,
          disabled: requestIsEmpty(data.request),
          run: () => {
            data.request = defaultRequest();
            data.savedRequestId = null;
            data.savedFolderId = null;
            data.lastSavedRequest = null;
            state.response = null;
            state.error = null;
            state.cancelled = false;
            syncFormFromData();
            renderAll();
            app.persist();
            app.refreshTabTitle(tab.id);
          },
        },
      ],
      { align: 'right' }
    );
  });

  async function copyCurl() {
    const ok = await copyText(toCurl(data.request));
    toast(ok ? '已复制 cURL 命令' : '复制失败', ok ? 'success' : 'error', ok ? 'copy' : 'alert');
  }

  /* ======================================================================
     发送
     ====================================================================== */

  function setLoading(loading) {
    state.loading = loading;
    sendButton.classList.toggle('hidden', loading);
    stopButton.classList.toggle('hidden', !loading);
    sendButton.disabled = requestIsEmpty(data.request);
  }

  function updateSendState() {
    if (state.loading) return;
    sendButton.disabled = requestIsEmpty(data.request);
  }

  async function send() {
    if (state.loading || requestIsEmpty(data.request)) return;
    const sentRequest = clone(data.request);
    const controller = new AbortController();
    state.controller = controller;
    state.error = null;
    state.cancelled = false;
    state.response = null;
    setLoading(true);
    renderResponse();

    let response = null;
    let errorMessage = null;
    let cancelled = false;

    try {
      response = await sendRequest(sentRequest, {
        mode: store.state.proxyMode,
        signal: controller.signal,
      });
    } catch (error) {
      if (error?.kind === 'cancelled') cancelled = true;
      else errorMessage = error?.message || String(error);
    }

    if (state.controller !== controller) return;
    state.controller = null;
    setLoading(false);
    state.response = response;
    state.error = errorMessage;
    state.cancelled = cancelled;
    renderResponse();

    await recordHistory(sentRequest, response, cancelled ? '请求已取消' : errorMessage);
  }

  async function recordHistory(request, response, error) {
    try {
      await historyStore.add({
        request,
        response,
        error,
        savedRequestId: data.savedRequestId,
      });
      await loadHistory(state.historyQuery);
    } catch (err) {
      console.warn('[devkit] 写历史失败', err);
    }
  }

  /* ======================================================================
     响应渲染
     ====================================================================== */

  function renderResponse() {
    if (state.previewUrl) {
      URL.revokeObjectURL(state.previewUrl);
      state.previewUrl = null;
    }
    responsePane.replaceChildren();

    if (state.error) {
      responsePane.append(errorBar(state.error));
    }

    if (state.response) {
      const response = state.response;
      const blocks = [
        statusBar(response),
        noticeBar(response),
        truncationBar(response),
        responseTabs(response),
      ].filter(Boolean);
      responsePane.append(...blocks);
      return;
    }

    if (state.loading) {
      responsePane.append(
        h(
          'div',
          { class: 'response-state' },
          h('div', { class: 'spinner' }),
          h('div', { class: 'state-title' }, '正在发送请求…'),
          h('div', { class: 'state-desc' }, '等待服务器响应；可在请求栏点「停止」中断。')
        )
      );
      return;
    }

    if (state.cancelled) {
      responsePane.append(
        h(
          'div',
          { class: 'response-state' },
          h('div', { class: 'empty-icon' }, icon('stop', 26)),
          h('div', { class: 'state-title' }, '请求已取消'),
          h('div', { class: 'state-desc' }, '已中断在途请求。可在请求栏调整超时后重新发送。')
        )
      );
      return;
    }

    responsePane.append(
      h(
        'div',
        { class: 'response-state' },
        h('div', { class: 'empty-icon' }, icon(state.error ? 'alert' : 'arrows', 28)),
        h('div', { class: 'state-title' }, state.error ? '请求未完成' : '尚未发送请求'),
        h(
          'div',
          { class: 'state-desc' },
          state.error
            ? '可检查地址与网络，或在设置中把请求通道切换为本地代理后重试。'
            : '填写地址后点「发送」或按 ⌘↵。响应会在这里展示，并自动记录到历史。'
        )
      )
    );
  }

  function statusBar(response) {
    const info = statusInfo(response.status);
    const sizeText = `${response.isTruncated ? '≥ ' : ''}${formatBytes(response.bodyBytes.length)}`;
    const channel = response.channel === 'proxy' ? '本地代理' : '浏览器直连';
    return h(
      'div',
      { class: 'response-status' },
      h(
        'span',
        { class: 'stat' },
        h('span', { class: 'status-dot', style: { background: info.color } }),
        h('span', { class: 'status-code' }, String(response.status)),
        h('span', { class: 'status-label' }, info.label)
      ),
      h('span', { class: 'stat' }, icon('clock', 12), formatDuration(response.durationMs)),
      h('span', { class: 'stat' }, icon('server', 12), sizeText),
      response.contentType
        ? h('span', { class: 'content-type', title: response.contentType }, response.contentType)
        : null,
      h('div', { class: 'spacer' }),
      h('span', { class: 'status-label', title: channel }, channel)
    );
  }

  function noticeBar(response) {
    if (response.bodyIgnored) {
      return h(
        'div',
        { class: 'notice-bar warn' },
        icon('alert', 12),
        h('span', { class: 'notice-text' }, `${response.requestMethod || 'GET / HEAD'} 请求不发送 Body，已忽略请求体。`)
      );
    }
    if (response.channel === 'proxy' && response.proxyDropped?.length) {
      return h(
        'div',
        { class: 'notice-bar warn' },
        icon('alert', 12),
        h(
          'span',
          { class: 'notice-text' },
          `代理会按目标地址重算传输头，以下设置已忽略：${response.proxyDropped.join('、')}。`
        )
      );
    }
    const forbidden = response.forbidden || [];
    if (response.channel !== 'proxy' && forbidden.length) {
      return h(
        'div',
        { class: 'notice-bar warn' },
        icon('alert', 12),
        h(
          'span',
          { class: 'notice-text' },
          `浏览器禁止脚本设置 ${forbidden.join('、')}，已自动忽略。需要完整控制请求头时请使用本地代理通道。`
        )
      );
    }
    if (response.channel === 'direct' && response.crossOrigin) {
      return h(
        'div',
        { class: 'notice-bar' },
        icon('info', 12),
        h('span', { class: 'notice-text' }, '直连模式：浏览器只暴露 CORS 允许的响应头。需要完整响应头或遇到跨域失败时，改用本地代理。')
      );
    }
    return null;
  }

  function truncationBar(response) {
    if (!response.isTruncated) return null;
    return h(
      'div',
      { class: 'notice-bar warn' },
      icon('alert', 12),
      h(
        'span',
        { class: 'notice-text' },
        `响应体超过 ${formatBytes(10_000_000)} 上限，已中止接收，仅保留前 ${formatBytes(response.bodyBytes.length)}。`
      )
    );
  }

  function responseTabs(response) {
    const text = responseText(response);
    const isJSON = text && looksJSON(text);
    let active = state.responseTab || 'pretty';
    const host = h('div', { class: 'response-body' });

    const tabs = [
      ['pretty', 'Pretty'],
      ['raw', 'Raw'],
      ['headers', 'Headers'],
      ['preview', 'Preview'],
    ];
    const buttons = new Map();
    const seg = h('div', { class: 'segmented' });
    for (const [key, label] of tabs) {
      const button = h('button', { role: 'tab', onclick: () => setActive(key) }, label);
      buttons.set(key, button);
      seg.append(button);
    }

    const copyBtn = h('button', { class: 'tb-btn', title: '复制当前视图内容' }, icon('copy', 13), h('span', null, '复制'));

    function setActive(key) {
      active = key;
      state.responseTab = key;
      for (const [name, button] of buttons) button.setAttribute('aria-selected', String(name === key));
      copyBtn.classList.toggle('hidden', key !== 'pretty' && key !== 'raw');
      renderBody();
    }

    function renderBody() {
      host.replaceChildren();
      host.style.background = '';
      if (active === 'headers') {
        const list = h('div', { class: 'headers-view' });
        if (!response.headers.length) {
          list.append(h('div', { class: 'empty', style: { minHeight: '100px' } }, '没有可读取的响应头'));
        }
        response.headers.forEach(([key, value]) => {
          list.append(
            h('div', { class: 'header-line' }, h('div', { class: 'header-key' }, key), h('div', { class: 'header-val' }, value))
          );
        });
        host.append(list);
        return;
      }

      if (active === 'preview') {
        const type = String(response.contentType || '').toLowerCase();
        if (type.includes('text/html') && text) {
          const frame = h('iframe', {
            class: 'preview-frame',
            sandbox: 'allow-scripts allow-forms allow-popups',
            title: 'HTML 预览',
          });
          frame.srcdoc = text;
          host.style.background = '#fff';
          host.append(frame);
          return;
        }
        if (type.startsWith('image/') && response.bodyBytes.length) {
          const blob = new Blob([response.bodyBytes], { type: response.contentType || 'image/png' });
          state.previewUrl = URL.createObjectURL(blob);
          host.append(
            h('div', { class: 'preview-image-wrap' }, h('img', { src: state.previewUrl, alt: '响应图片' }))
          );
          return;
        }
        host.append(
          h(
            'div',
            { class: 'empty', style: { minHeight: '100%' } },
            h('div', { class: 'empty-icon' }, icon('image', 26)),
            h('div', { class: 'empty-title' }, '无法预览'),
            h('div', { class: 'empty-desc' }, 'Preview 仅支持 HTML 与图片响应。')
          )
        );
        return;
      }

      host.style.background = '';
      if (!text) {
        host.append(
          h(
            'div',
            { class: 'empty', style: { minHeight: '100%' } },
            h('div', { class: 'empty-icon' }, icon('file', 26)),
            h('div', { class: 'empty-title' }, '二进制内容'),
            h('div', { class: 'empty-desc' }, `响应体无法以文本显示（${formatBytes(response.bodyBytes.length)}）。`)
          )
        );
        return;
      }

      const shown = active === 'pretty' && isJSON ? prettyText(text) : text;
      const pre = h('pre', { class: 'code' });
      if (active === 'pretty' && isJSON) pre.innerHTML = highlightJSON(shown);
      else pre.textContent = shown;

      copyBtn.onclick = async () => {
        const ok = await copyText(pre.textContent);
        if (ok) flashButton(copyBtn, '复制成功');
      };

      host.append(h('div', { class: 'code-wrap' }, pre));
    }

    const headerRow = h('div', { class: 'response-tabs' }, seg, h('div', { class: 'spacer' }), copyBtn);
    setActive(active);

    return h('div', { class: 'response-shell' }, headerRow, host);
  }

  function looksJSON(text) {
    const trimmed = String(text || '').trim();
    if (!trimmed) return false;
    if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return false;
    try {
      JSON.parse(trimmed);
      return true;
    } catch {
      return false;
    }
  }

  function prettyText(text) {
    try {
      return JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      return text;
    }
  }

  function errorBar(message) {
    return h('div', { class: 'error-bar' }, icon('alert', 13), h('span', null, message));
  }

  /* ======================================================================
     编辑器元信息 / 保存
     ====================================================================== */

  function updateMeta() {
    if (data.savedRequestId) {
      const record = store.state.httpCollections.requests.find((item) => item.id === data.savedRequestId);
      if (record) {
        const dirty = requestIsDirty(data);
        editorMeta.textContent = dirty ? `${record.name} · 未保存改动` : `已保存 · ${record.name}`;
        editorMeta.className = `editor-meta ${dirty ? 'dirty' : ''}`;
        saveButton.disabled = !dirty;
        saveButton.title = dirty ? '保存请求 (⌘S)' : '当前请求已保存';
        return;
      }
      // 记录已被删除：解绑
      data.savedRequestId = null;
      data.lastSavedRequest = null;
    }
    editorMeta.textContent = requestIsEmpty(data.request) ? '未保存' : '未保存的新请求';
    editorMeta.className = 'editor-meta';
    saveButton.disabled = requestIsEmpty(data.request);
    saveButton.title = '保存请求 (⌘S)';
  }

  function renderStatusMeta() {
    updateMeta();
  }

  saveButton.addEventListener('click', () => requestSave());

  function requestSave() {
    if (data.savedRequestId) {
      const record = store.state.httpCollections.requests.find((item) => item.id === data.savedRequestId);
      if (record) {
        record.request = clone(data.request);
        record.updatedAt = Date.now();
        data.savedFolderId = record.folderId ?? null;
        data.lastSavedRequest = clone(data.request);
        store.touch();
        updateMeta();
        toast('已保存', 'success', 'check');
        app.refreshTabTitle(tab.id);
        return;
      }
      data.savedRequestId = null;
      data.lastSavedRequest = null;
    }
    openSaveDialog(false);
  }

  function openSaveDialog(asNew) {
    const suggestedName =
      (data.savedRequestId &&
        store.state.httpCollections.requests.find((item) => item.id === data.savedRequestId)?.name) ||
      hostOf(data.request.urlString) ||
      '未命名请求';

    const nameInput = h('input', { class: 'input', value: asNew ? `${suggestedName} 副本` : suggestedName });
    const options = folderOptions(store.state);
    const select = h('select', { class: 'input' });
    for (const option of options) {
      select.append(
        h('option', { value: option.id ?? '', selected: (data.savedFolderId ?? null) === option.id }, `${'　'.repeat(option.depth)}${option.label}`)
      );
    }
    const newFolderInput = h('input', { class: 'input', placeholder: '新建文件夹名称' });
    const newFolderButton = h(
      'button',
      { class: 'btn sm' },
      icon('folderPlus', 12),
      '新建文件夹'
    );

    const folderField = h(
      'div',
      { class: 'field' },
      h('label', null, '保存到文件夹'),
      select,
      h('div', { class: 'field-row', style: { marginTop: '6px' } }, newFolderInput, newFolderButton)
    );

    const body = h('div', null, h('div', { class: 'field' }, h('label', null, '名称'), nameInput), folderField);
    let dialog;

    const doSave = () => {
      const name = nameInput.value.trim();
      if (!name) {
        nameInput.focus();
        return;
      }
      const folderId = select.value || null;
      const collections = store.state.httpCollections;
      if (asNew || !data.savedRequestId) {
        const record = {
          id: uid('req'),
          folderId,
          name,
          request: clone(data.request),
          createdAt: Date.now(),
          updatedAt: Date.now(),
        };
        collections.requests.push(record);
        data.savedRequestId = record.id;
      } else {
        const record = collections.requests.find((item) => item.id === data.savedRequestId);
        if (record) {
          record.name = name;
          record.folderId = folderId;
          record.request = clone(data.request);
          record.updatedAt = Date.now();
        }
      }
      data.savedFolderId = folderId;
      data.lastSavedRequest = clone(data.request);
      store.touch();
      updateMeta();
      app.refreshTabTitle(tab.id);
      toast('已保存到集合', 'success', 'check');
      dialog.close();
    };

    newFolderButton.addEventListener('click', () => {
      const name = newFolderInput.value.trim();
      if (!name) {
        newFolderInput.focus();
        return;
      }
      const folder = createFolder(name, select.value || null);
      if (folder) {
        select.append(
          h('option', { value: folder.id, selected: true }, `${'　'.repeat(folderOptions(store.state).find((o) => o.id === folder.id)?.depth ?? 1)}${folder.name}`)
        );
        select.value = folder.id;
        newFolderInput.value = '';
      }
    });

    nameInput.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        doSave();
      }
    });

    dialog = openModal({
      title: '保存请求',
      width: 420,
      body,
      footer: [
        h('button', { class: 'btn', onclick: () => dialog.close() }, '取消'),
        h('button', { class: 'btn primary', onclick: doSave }, '保存'),
      ],
    });
  }

  function hostOf(raw) {
    try {
      const value = String(raw || '').trim();
      if (!value) return null;
      return new URL(/^[a-zA-Z][a-zA-Z\d+.-]*:\/\//.test(value) ? value : `https://${value}`).host || null;
    } catch {
      return null;
    }
  }

  /* ======================================================================
     历史
     ====================================================================== */

  const runHistorySearch = debounce(async (query) => {
    state.historyQuery = query;
    await loadHistory(query);
  }, 140);

  historySearch.addEventListener('input', () => runHistorySearch(historySearch.value));
  historyClear.addEventListener('click', async () => {
    if (!state.history.length) return;
    const ok = await confirmDialog({
      title: '清空全部历史',
      message: `将删除 ${state.history.length} 条 HTTP 历史记录，此操作不可撤销。`,
      confirmText: '清空',
      danger: true,
    });
    if (!ok) return;
    await historyStore.clear();
    state.history = [];
    renderHistory();
    toast('历史已清空', 'success', 'check');
  });

  async function loadHistory(query = '') {
    try {
      state.history = await historyStore.search(query);
      state.historyLoaded = true;
    } catch (error) {
      console.warn('[devkit] 读取历史失败', error);
      state.history = [];
    }
    renderHistory();
  }

  function renderHistory() {
    historyList.replaceChildren();
    historyClear.disabled = !state.history.length;
    if (!state.historyLoaded) {
      historyList.append(h('div', { class: 'empty' }, h('div', { class: 'spinner sm' })));
      return;
    }
    if (!state.history.length) {
      historyList.append(
        h(
          'div',
          { class: 'empty history-empty' },
          h('div', { class: 'empty-icon' }, icon('clock', 26)),
          h('div', { class: 'empty-title' }, state.historyQuery ? '没有匹配的历史' : '暂无历史'),
          h('div', { class: 'empty-desc' }, '发送请求后会自动记录在这里。')
        )
      );
      return;
    }

    for (const record of state.history) {
      const code = record.response?.status;
      const info = code ? statusInfo(code) : null;
      const row = h(
        'div',
        {
          class: 'history-row',
          title: `${record.method} ${record.url}`,
          onclick: () => openHistoryDetail(record),
          oncontextmenu: (event) => {
            event.preventDefault();
            openMenu(row, [
              { label: '查看详情', icon: 'eye', run: () => openHistoryDetail(record) },
              { label: '载入到编辑器', icon: 'corner', run: () => applyHistory(record) },
              { sep: true },
              { label: '删除', icon: 'trash', danger: true, run: () => removeHistory(record) },
            ], { at: { x: event.clientX, y: event.clientY } });
          },
        },
        h('span', { class: 'h-method', style: { color: methodColor(record.method) } }, record.method.toUpperCase()),
        h('span', { class: 'h-url' }, record.url || '(空地址)'),
        code
          ? h('span', { class: 'h-code', style: { color: info.color } }, String(code))
          : h('span', { class: 'h-code', style: { color: 'var(--text-3)' } }, '失败'),
        h('span', { class: 'h-time' }, historyTime(record.at))
      );
      historyList.append(row);
    }
  }

  async function removeHistory(record) {
    await historyStore.remove(record.id);
    state.history = state.history.filter((item) => item.id !== record.id);
    renderHistory();
  }

  function applyHistory(record) {
    data.request = clone(record.request);
    state.response = null;
    state.error = null;
    state.cancelled = false;
    syncFormFromData();
    renderAll();
    app.persist();
    app.refreshTabTitle(tab.id);
    toast('已载入到编辑器', 'success', 'corner');
  }

  function openHistoryDetail(record) {
    let tab = 'request';
    const host = h('div');

    const reqTab = h('button', { class: 'detail-tab', onclick: () => setTab('request') }, '请求');
    const resTab = h('button', { class: 'detail-tab', onclick: () => setTab('response') }, '响应');

    function setTab(next) {
      tab = next;
      reqTab.setAttribute('aria-selected', String(tab === 'request'));
      resTab.setAttribute('aria-selected', String(tab === 'response'));
      renderDetail();
    }

    function renderDetail() {
      host.replaceChildren();
      const request = record.request;
      const meta = h(
        'div',
        { class: 'detail-meta' },
        h('span', null, fullTime(record.at)),
        h('span', null, request.method),
        h('span', { style: { fontFamily: 'var(--font-mono)' } }, request.urlString || '(空地址)')
      );
      host.append(meta);

      if (tab === 'request') {
        host.append(h('div', { class: 'detail-sub' }, '请求头'));
        let headers = [];
        try {
          headers = buildRequestSpec(request).headers.map(([key, value]) => ({ key, value }));
        } catch {
          headers = (request.headers || []).filter((header) => header.enabled && header.key);
        }
        host.append(
          headers.length
            ? h(
                'div',
                { class: 'detail-code' },
                h(
                  'pre',
                  { class: 'code' },
                  headers.map((header) => `${header.key}: ${header.value}`).join('\n')
                )
              )
            : h('div', { class: 'hint-line' }, '无')
        );
        host.append(h('div', { class: 'detail-sub' }, '请求体'));
        const payload = bodyPayload(request.body);
        host.append(
          payload
            ? h('div', { class: 'detail-code' }, h('pre', { class: 'code' }, payload))
            : h('div', { class: 'hint-line' }, '无')
        );
        return;
      }

      if (!record.response) {
        host.append(
          h(
            'div',
            { class: 'empty', style: { minHeight: '120px' } },
            h('div', { class: 'empty-icon' }, icon('alert', 24)),
            h('div', { class: 'empty-title' }, record.error || '本次请求没有响应')
          )
        );
        return;
      }

      const response = record.response;
      const info = statusInfo(response.status);
      host.append(
        h(
          'div',
          { class: 'detail-meta' },
          h('span', { style: { color: info.color, fontWeight: '600' } }, String(response.status)),
          h('span', null, formatDuration(response.durationMs)),
          h('span', null, formatBytes(response.sizeBytes)),
          response.isTruncated ? h('span', null, '（已截断）') : null
        ),
        h('div', { class: 'detail-sub' }, '响应头'),
        response.headers?.length
          ? h(
              'div',
              { class: 'detail-code' },
              h(
                'pre',
                { class: 'code' },
                response.headers.map(([key, value]) => `${key}: ${value}`).join('\n')
              )
            )
          : h('div', { class: 'hint-line' }, '无'),
        h('div', { class: 'detail-sub' }, '响应体'),
        historyBody(record)
      );
    }

    function historyBody(record) {
      if (!record.response?.bodyBase64) return h('div', { class: 'hint-line' }, '空响应体');
      const bytes = base64ToBytes(record.response.bodyBase64);
      const type = String(record.response.contentType || '').toLowerCase();
      if (type.startsWith('image/') || type.includes('octet-stream')) {
        return h('div', { class: 'hint-line' }, `二进制内容（${formatBytes(bytes.length)}），不在此展示。`);
      }
      const text = decodeBody(bytes, record.response.contentType);
      return h('div', { class: 'detail-code' }, h('pre', { class: 'code' }, text));
    }

    setTab('request');

    const modal = openModal({
      title: '请求详情',
      width: 600,
      body: h('div', null, h('div', { class: 'detail-tabs' }, reqTab, resTab), host),
      footer: [
        h('div', { class: 'spacer' }),
        h(
          'button',
          {
            class: 'btn',
            onclick: () => {
              applyHistory(record);
              modal.close();
            },
          },
          icon('corner', 13),
          '载入到编辑器'
        ),
        h('button', { class: 'btn primary', onclick: () => modal.close() }, '完成'),
      ],
    });
  }

  /* ======================================================================
     同步与初始化
     ====================================================================== */

  function syncFormFromData() {
    urlInput.value = data.request.urlString;
    updateSendState();
    methodLabel.textContent = data.request.method;
    bodyTextarea.value = data.request.body.text ?? '';
    timeoutLabel.textContent = formatTimeout(data.request.timeoutSeconds);
    renderParams();
    renderHeaders();
    renderBody();
    renderAuth();
    updateMeta();
  }

  function showSection(key) {
    state.section = key;
    for (const [name, button] of sectionButtons) {
      button.setAttribute('aria-selected', String(name === key));
    }
    for (const [name, pane] of Object.entries(panes)) {
      pane.classList.toggle('hidden', name !== key);
    }
    if (key === 'history') loadHistory(state.historyQuery);
  }

  function renderAll() {
    renderMethod();
    syncFormFromData();
    showSection(state.section);
    renderResponse();
  }

  /* — 分区拖拽 — */

  let dragging = false;
  divider.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    dragging = true;
    divider.classList.add('is-active');
    document.body.classList.add('is-row-resizing');
    const rect = split.getBoundingClientRect();
    const shield = h('div', { class: 'drag-shield' });
    document.body.append(shield);

    const move = (moveEvent) => {
      const ratio = (moveEvent.clientY - rect.top) / rect.height;
      const clamped = Math.min(0.85, Math.max(0.15, ratio));
      store.state.httpEditorRatio = clamped;
      applyRatio();
    };
    const up = () => {
      dragging = false;
      divider.classList.remove('is-active');
      document.body.classList.remove('is-row-resizing');
      shield.remove();
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      store.touch();
      view.resize?.();
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  });

  divider.addEventListener('dblclick', () => {
    store.state.httpEditorRatio = 0.5;
    applyRatio();
    store.touch();
  });

  function applyRatio() {
    const total = split.clientHeight;
    if (!total) return;
    const height = Math.max(120, Math.min(total - 120, Math.round(total * store.state.httpEditorRatio)));
    editorPane.style.height = `${height}px`;
    responsePane.style.height = `${Math.max(120, total - height - 7)}px`;
  }

  /* — 启动检查 — */

  checkProxy().then(() => {
    if (store.state.proxyMode === 'proxy' && !proxyStatus.available) {
      toast('本地代理不可用，请用 node server.js 启动服务', 'warn', 'wifiOff');
    }
  });

  renderAll();
  loadHistory();
  requestAnimationFrame(() => {
    applyRatio();
    renderStatusMeta();
  });

  const view = {
    el: root,
    focus() {
      urlInput.focus();
    },
    resize() {
      applyRatio();
    },
    reloadData() {
      renderAll();
    },
    refreshMeta() {
      updateMeta();
    },
    send,
    save: requestSave,
    getTitle() {
      if (data.savedRequestId) {
        const record = store.state.httpCollections.requests.find((item) => item.id === data.savedRequestId);
        if (record) return record.name;
      }
      try {
        const url = new URL(appliedURLString(data.request));
        if (url.host) return url.host;
      } catch {
        /* ignore */
      }
      return null;
    },
    hasUnsaved() {
      return requestIsDirty(data);
    },
    destroy() {
      state.controller?.abort();
      if (state.previewUrl) URL.revokeObjectURL(state.previewUrl);
    },
  };

  return view;
}
