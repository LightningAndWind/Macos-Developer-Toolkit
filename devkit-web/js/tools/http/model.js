/* ==========================================================================
   HTTP 请求模型与派生逻辑（对齐 mac 端 HTTPRequestModel）
   ========================================================================== */

import { uid } from '../../ui/dom.js';

export const METHOD_PRESETS = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS'];
export const TIMEOUT_PRESETS = [15, 30, 60, 120, 300];
export const MIN_TIMEOUT = 1;
export const MAX_TIMEOUT = 3600;
export const MAX_BODY_BYTES = 10_000_000;

export function defaultRequest() {
  return {
    method: 'GET',
    urlString: '',
    params: [],
    headers: [],
    body: { kind: 'none', text: '', formFields: [] },
    auth: { kind: 'none', token: '', username: '', password: '' },
    timeoutSeconds: 30,
  };
}

export function newKV(key = '', value = '', enabled = true) {
  return { id: uid('kv'), key, value, enabled };
}

export function authHeaderValue(auth) {
  if (!auth) return null;
  if (auth.kind === 'bearer') return auth.token ? `Bearer ${auth.token}` : null;
  if (auth.kind === 'basic') {
    if (!auth.username && !auth.password) return null;
    return `Basic ${base64Utf8(`${auth.username}:${auth.password}`)}`;
  }
  return null;
}

export function base64Utf8(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function encodeFormComponent(text) {
  return encodeURIComponent(text).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

export function bodyPayload(body) {
  if (!body || body.kind === 'none') return null;
  if (body.kind === 'form') {
    const pairs = (body.formFields || [])
      .filter((field) => field.enabled && field.key)
      .map((field) => `${encodeFormComponent(field.key)}=${encodeFormComponent(field.value)}`);
    return pairs.length ? pairs.join('&') : null;
  }
  return body.text ? body.text : null;
}

export function bodyContentType(body) {
  switch (body?.kind) {
    case 'json': return 'application/json';
    case 'form': return 'application/x-www-form-urlencoded';
    case 'raw': return 'text/plain';
    default: return null;
  }
}


export function enabledHeaders(request) {
  return (request.headers || [])
    .filter((header) => header.enabled && header.key)
    .map((header) => [header.key, header.value]);
}

function normalizedURL(raw) {
  const trimmed = String(raw || '').trim();
  if (!trimmed) return '';
  if (!/^[a-zA-Z][a-zA-Z\d+.-]*:\/\//.test(trimmed)) {
    // 本地开发常用 localhost / 127.0.0.1，默认走 http 更符合预期。
    if (/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?(\/|$)/i.test(trimmed)) return `http://${trimmed}`;
    return `https://${trimmed}`;
  }
  return trimmed;
}

/** 合并 URL query 与启用参数：参数表格覆盖同名项，禁用参数从 query 移除。 */
export function appliedURLString(request) {
  const raw = normalizedURL(request.urlString);
  if (!raw) return '';
  let url;
  try {
    url = new URL(raw);
  } catch {
    return raw;
  }

  for (const param of request.params || []) {
    if (!param.enabled || !param.key) continue;
    if (param.value === '') url.searchParams.delete(param.key);
    url.searchParams.set(param.key, param.value);
    if (param.value === '') {
      // URLSearchParams 会把空值序列化成 "key="，与 mac 端「value 为 nil」等价，保留即可。
    }
  }

  const disabled = new Set((request.params || []).filter((p) => !p.enabled && p.key).map((p) => p.key));
  if (disabled.size) {
    for (const key of disabled) url.searchParams.delete(key);
  }
  return url.toString();
}

/** 把 URL 上的 query 拉进参数表格（跳过已存在的 key）。 */
export function syncQueryToParams(request) {
  let url;
  try {
    url = new URL(normalizedURL(request.urlString));
  } catch {
    return 0;
  }
  let added = 0;
  for (const [key, value] of url.searchParams.entries()) {
    if ((request.params || []).some((param) => param.key === key)) continue;
    request.params.push(newKV(key, value));
    added += 1;
  }
  return added;
}

export function requestIsEmpty(request) {
  return !String(request.urlString || '').trim();
}

export function requestIsDirty(data) {
  if (!data || requestIsEmpty(data.request)) return false;
  // 新建请求（lastSavedRequest 为 null）有内容即视为未保存
  return JSON.stringify(data.request) !== JSON.stringify(data.lastSavedRequest ?? null);
}

export function effectiveTimeout(request) {
  const value = Number(request?.timeoutSeconds);
  if (!Number.isFinite(value)) return 30;
  return Math.min(MAX_TIMEOUT, Math.max(MIN_TIMEOUT, Math.round(value)));
}

/** 浏览器不允许脚本设置的请求头：发送前提示，而不是静默丢弃。 */
const FORBIDDEN_HEADERS = new Set([
  'accept-charset',
  'accept-encoding',
  'access-control-request-headers',
  'access-control-request-method',
  'connection',
  'content-length',
  'cookie',
  'cookie2',
  'date',
  'dnt',
  'expect',
  'host',
  'keep-alive',
  'origin',
  'referer',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'via',
]);

export function forbiddenHeaders(headers) {
  return headers
    .filter(([key]) => {
      const lower = String(key).toLowerCase();
      return FORBIDDEN_HEADERS.has(lower) || lower.startsWith('proxy-') || lower.startsWith('sec-');
    })
    .map(([key]) => key);
}

/** 组装最终要发送的请求描述。 */
export function buildRequestSpec(request) {
  const url = appliedURLString(request);
  const method = String(request.method || 'GET').trim().toUpperCase();
  const headers = enabledHeaders(request);
  const auth = authHeaderValue(request.auth);
  if (auth) headers.push(['Authorization', auth]);

  let payload = bodyPayload(request.body);
  const contentType = bodyContentType(request.body);
  // 浏览器与多数服务端都不发 GET / HEAD 的 body，这里统一丢弃并在响应区提示。
  const bodyIgnored = payload !== null && (method === 'GET' || method === 'HEAD');
  if (bodyIgnored) payload = null;

  if (payload !== null && contentType) {
    const hasContentType = headers.some(([key]) => key.toLowerCase() === 'content-type');
    if (!hasContentType) headers.push(['Content-Type', contentType]);
  }

  return {
    url,
    method,
    headers,
    payload,
    contentType,
    bodyIgnored,
    forbidden: forbiddenHeaders(headers),
    timeout: effectiveTimeout(request),
  };
}

/** cURL 导出（与 mac 端 CurlExporter 同款排版）。 */
export function toCurl(request) {
  const spec = buildRequestSpec(request);
  const quote = (text) => `'${String(text).replaceAll("'", "'\\''")}'`;
  const lines = ['curl'];
  if (spec.method !== 'GET') lines.push(`  -X ${spec.method}`);
  for (const [key, value] of spec.headers) {
    if (key.toLowerCase() === 'content-type' && spec.payload !== null) continue;
    lines.push(`  -H ${quote(`${key}: ${value}`)}`);
  }
  if (spec.payload !== null) {
    if (spec.contentType) lines.push(`  -H ${quote(`Content-Type: ${spec.contentType}`)}`);
    lines.push(`  --data ${quote(spec.payload)}`);
  }
  lines.push(`  ${quote(spec.url)}`);
  return lines.join(' \\\n');
}


/** 把从本地存储 / 旧版本读出的请求补齐为完整结构。 */
export function normalizeRequest(raw) {
  const base = defaultRequest();
  if (!raw || typeof raw !== 'object') return base;
  const request = { ...base, ...raw };
  request.params = normalizeKV(raw.params);
  request.headers = normalizeKV(raw.headers);
  request.body = { ...base.body, ...(raw.body && typeof raw.body === 'object' ? raw.body : {}) };
  request.body.formFields = normalizeKV(raw.body?.formFields);
  request.auth = { ...base.auth, ...(raw.auth && typeof raw.auth === 'object' ? raw.auth : {}) };
  request.timeoutSeconds = effectiveTimeout(request);
  return request;
}

function normalizeKV(items) {
  if (!Array.isArray(items)) return [];
  return items
    .filter((item) => item && typeof item === 'object')
    .map((item) => ({
      id: item.id || uid('kv'),
      key: typeof item.key === 'string' ? item.key : '',
      value: typeof item.value === 'string' ? item.value : '',
      enabled: item.enabled !== false,
    }));
}
