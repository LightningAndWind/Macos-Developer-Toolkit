/* ==========================================================================
   HTTP 发送器
   两种通道：
   - 直连：浏览器 fetch，受 CORS 限制；
   - 代理：同源 Node 服务 /api/proxy，可完整读取响应头、绕过 CORS。
   ========================================================================== */

import { MAX_BODY_BYTES, buildRequestSpec } from './model.js';
import { base64ToBytes } from './history.js';

export const proxyStatus = {
  available: false,
  checked: false,
  checking: false,
  lastError: null,
};

export class CancelledError extends Error {
  constructor() {
    super('请求已取消');
    this.kind = 'cancelled';
  }
}

export class TimeoutError extends Error {
  constructor(seconds) {
    super(`请求超时：${seconds} 秒内未收到响应数据`);
    this.kind = 'timeout';
  }
}

export class TransferError extends Error {
  constructor(message) {
    super(message);
    this.kind = 'transfer';
  }
}

export async function checkProxy() {
  if (proxyStatus.checking) return proxyStatus.available;
  proxyStatus.checking = true;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1500);
    const response = await fetch('./api/health', { cache: 'no-store', signal: controller.signal });
    clearTimeout(timer);
    const data = response.ok ? await response.json() : null;
    proxyStatus.available = Boolean(data?.proxy);
    proxyStatus.lastError = null;
  } catch (error) {
    proxyStatus.available = false;
    proxyStatus.lastError = error?.message || '不可用';
  } finally {
    proxyStatus.checking = false;
    proxyStatus.checked = true;
  }
  return proxyStatus.available;
}

function contentTypeOf(headers) {
  const entry = headers.find(([key]) => key.toLowerCase() === 'content-type');
  return entry ? entry[1] : '';
}

function isBinaryType(contentType) {
  const ct = String(contentType || '').toLowerCase();
  return (
    ct.startsWith('image/') ||
    ct.startsWith('audio/') ||
    ct.startsWith('video/') ||
    ct.startsWith('font/') ||
    ct.includes('application/pdf') ||
    ct.includes('application/zip') ||
    ct.includes('application/octet-stream') ||
    ct.includes('application/x-tar') ||
    ct.includes('application/gzip')
  );
}

export function decodeBody(bytes, contentType = '') {
  if (!bytes || bytes.length === 0) return '';
  const match = /charset=([\w-]+)/i.exec(String(contentType || ''));
  const charset = match ? match[1].toLowerCase() : 'utf-8';
  try {
    return new TextDecoder(charset === 'gb2312' ? 'gbk' : charset, { fatal: false }).decode(bytes);
  } catch {
    return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  }
}

export function responseText(response) {
  if (!response) return null;
  if (isBinaryType(response.contentType)) return null;
  const text = decodeBody(response.bodyBytes, response.contentType);
  if (text === null) return null;
  if (text.includes('\u0000')) return null;
  return text;
}

function combineSignals(external) {
  const controller = new AbortController();
  let reason = null;
  const abort = (why) => {
    reason = why;
    controller.abort();
  };
  if (external) {
    if (external.aborted) abort('cancelled');
    else external.addEventListener('abort', () => abort('cancelled'), { once: true });
  }
  return { controller, getReason: () => reason };
}

function idleTimer(ms, onTimeout) {
  let timer = 0;
  const kick = () => {
    clearTimeout(timer);
    timer = setTimeout(onTimeout, ms);
  };
  const clear = () => clearTimeout(timer);
  return { kick, clear };
}

async function sendDirect(spec, signal) {
  const { controller, getReason } = combineSignals(signal);
  const timer = idleTimer(spec.timeout * 1000, () => {
    if (!controller.signal.aborted) controller.abort();
  });

  const start = performance.now();
  const headers = new Headers();
  for (const [key, value] of spec.headers) headers.append(key, value);

  let response;
  timer.kick();
  try {
    response = await fetch(spec.url, {
      method: spec.method,
      headers,
      body: spec.payload === null || ['GET', 'HEAD'].includes(spec.method) ? undefined : spec.payload,
      signal: controller.signal,
      cache: 'no-store',
      redirect: 'follow',
      credentials: 'same-origin',
    });
    timer.kick();
  } catch (error) {
    timer.clear();
    if (signal?.aborted) throw new CancelledError();
    if (error?.name === 'AbortError') {
      throw new TimeoutError(spec.timeout);
    }
    throw new TransferError(
      `网络请求失败：${error?.message || error}。若目标接口未开启 CORS，浏览器会拦截响应；可改用本地代理通道。`
    );
  }

  const chunks = [];
  let total = 0;
  let truncated = false;

  try {
    if (response.body) {
      const reader = response.body.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        timer.kick();
        if (total + value.length > MAX_BODY_BYTES) {
          const remain = MAX_BODY_BYTES - total;
          if (remain > 0) {
            chunks.push(value.subarray(0, remain));
            total += remain;
          }
          truncated = true;
          controller.abort();
          break;
        }
        chunks.push(value);
        total += value.length;
      }
    }
  } catch (error) {
    if (truncated) {
      // 主动中止接收：保留已收到的部分。
    } else if (signal?.aborted) {
      timer.clear();
      throw new CancelledError();
    } else if (error?.name === 'AbortError') {
      timer.clear();
      throw new TimeoutError(spec.timeout);
    } else {
      timer.clear();
      throw new TransferError(`读取响应失败：${error?.message || error}`);
    }
  }
  timer.clear();

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }

  const responseHeaders = [...response.headers.entries()];
  return {
    status: response.status,
    statusText: response.statusText,
    headers: responseHeaders,
    bodyBytes: merged,
    durationMs: Math.max(1, Math.round(performance.now() - start)),
    isTruncated: truncated,
    viaProxy: false,
    contentType: contentTypeOf(responseHeaders) || response.headers.get('content-type') || '',
    finalUrl: response.url,
  };
}

async function sendViaProxy(spec, signal) {
  const start = performance.now();
  const controller = new AbortController();
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) throw new CancelledError();
    signal.addEventListener('abort', onAbort, { once: true });
  }
  const timer = setTimeout(() => controller.abort(), (spec.timeout + 10) * 1000);

  let payload;
  try {
    const response = await fetch('./api/proxy', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Devkit-Proxy': '1' },
      body: JSON.stringify({
        url: spec.url,
        method: spec.method,
        headers: spec.headers,
        bodyText: spec.payload,
        timeoutMs: spec.timeout * 1000,
        maxBytes: MAX_BODY_BYTES,
      }),
      signal: controller.signal,
    });
    clearTimeout(timer);
    if (!response.ok) {
      let message = `本地代理返回 ${response.status}`;
      try {
        const data = await response.json();
        if (data?.error) message = data.error;
      } catch {
        /* ignore */
      }
      throw new TransferError(message);
    }
    payload = await response.json();
  } catch (error) {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
    if (signal?.aborted) throw new CancelledError();
    if (error?.name === 'AbortError') throw new TimeoutError(spec.timeout);
    if (error instanceof TransferError) throw error;
    throw new TransferError(
      `本地代理请求失败：${error?.message || error}。确认已通过 node server.js 启动服务，再试一次。`
    );
  }
  signal?.removeEventListener('abort', onAbort);

  if (!payload?.ok) {
    throw new TransferError(payload?.error || '本地代理未能完成请求');
  }

  const bytes = base64ToBytes(payload.bodyBase64 || '');
  const headers = Array.isArray(payload.headers) ? payload.headers : [];
  return {
    status: payload.status,
    statusText: payload.statusText || '',
    headers,
    bodyBytes: bytes,
    durationMs: payload.durationMs ?? Math.max(1, Math.round(performance.now() - start)),
    isTruncated: Boolean(payload.truncated),
    viaProxy: true,
    contentType: contentTypeOf(headers),
    finalUrl: payload.finalUrl || spec.url,
  };
}

/**
 * 发送请求。
 * mode: auto | direct | proxy
 */
export async function sendRequest(request, { mode = 'auto', signal } = {}) {
  const spec = buildRequestSpec(request);
  if (!spec.url) throw new TransferError('URL 为空，请填写包含协议头的完整地址。');
  let url;
  try {
    url = new URL(spec.url);
  } catch {
    throw new TransferError(`URL 无效：${spec.url}`);
  }
  if (!url.host) throw new TransferError(`URL 无效：${spec.url}`);

  let channel = mode;
  if (mode === 'auto') {
    if (!proxyStatus.checked) await checkProxy();
    channel = proxyStatus.available ? 'proxy' : 'direct';
  }

  const response = channel === 'proxy' ? await sendViaProxy(spec, signal) : await sendDirect(spec, signal);
  response.forbidden = spec.forbidden;
  response.bodyIgnored = Boolean(spec.bodyIgnored);
  response.requestMethod = spec.method;
  response.proxyDropped = spec.headers
    .filter(([key]) =>
      ['host', 'connection', 'content-length', 'transfer-encoding', 'accept-encoding'].includes(
        key.toLowerCase()
      )
    )
    .map(([key]) => key);
  response.channel = channel;
  response.requestHeaders = spec.headers;
  response.crossOrigin = url.origin !== window.location.origin;
  return response;
}

