#!/usr/bin/env node
/*
 * devkit web · 本地服务
 *
 * 1. 托管静态文件（index.html / css / js / assets）
 * 2. 提供 /api/proxy，绕过浏览器 CORS，并返回完整响应头
 *
 * 用法：node server.js  →  http://127.0.0.1:5173
 * 仅监听回环地址，不对外网开放。
 */

'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const dns = require('dns');
const net = require('net');
const { URL } = require('url');

const ROOT = __dirname;
const PORT = Number(process.env.PORT) || 5173;
// 本地跑只监听回环；部署环境（注入 PORT）必须监听 0.0.0.0 才能被反向代理访问。
const PUBLIC_MODE = Boolean(process.env.PORT);
const HOST = process.env.HOST || (PUBLIC_MODE ? '0.0.0.0' : '127.0.0.1');
const MAX_BODY_BYTES = 10_000_000;
const MAX_REQUEST_BYTES = 24 * 1024 * 1024;
const MAX_REDIRECTS = 5;
const RATE_LIMIT_PER_MINUTE = 120;
const MAX_CONCURRENT_PROXY = 12;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
};

function isPrivateAddress(ip) {
  if (!ip) return true;
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split('.').map(Number);
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true;
    if (a >= 224) return true;
    return false;
  }
  const lower = String(ip).toLowerCase();
  if (lower === '::' || lower === '::1') return true;
  if (lower.startsWith('fc') || lower.startsWith('fd')) return true;
  if (lower.startsWith('fe80')) return true;
  if (lower.startsWith('::ffff:')) return isPrivateAddress(lower.slice(7));
  return false;
}

/**
 * 公网部署时的 DNS 解析守卫：拒绝解析到内网 / 回环 / 链路本地地址，
 * 防止代理被用来访问沙箱内部服务或云元数据接口。
 */
function safeLookup(hostname, options, callback) {
  const opts = typeof options === 'number' ? { family: options } : { ...(options || {}) };
  dns.lookup(hostname, { ...opts, all: true }, (error, addresses) => {
    if (error) {
      callback(error);
      return;
    }
    for (const item of addresses) {
      if (isPrivateAddress(item.address)) {
        const blocked = new Error('目标地址位于内网，公网部署下已拒绝该请求');
        blocked.code = 'EPRIVATE';
        callback(blocked);
        return;
      }
    }
    if (opts.all) callback(null, addresses);
    else callback(null, addresses[0].address, addresses[0].family);
  });
}

const rateBuckets = new Map();
let activeProxy = 0;

function acquireProxySlot(ip) {
  if (!PUBLIC_MODE) return true;
  const now = Date.now();
  let bucket = rateBuckets.get(ip);
  if (!bucket || now - bucket.start > 60_000) {
    bucket = { start: now, count: 0 };
    rateBuckets.set(ip, bucket);
  }
  if (bucket.count >= RATE_LIMIT_PER_MINUTE || activeProxy >= MAX_CONCURRENT_PROXY) return false;
  bucket.count += 1;
  activeProxy += 1;
  return true;
}

function releaseProxySlot() {
  if (!PUBLIC_MODE) return;
  activeProxy = Math.max(0, activeProxy - 1);
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, bucket] of rateBuckets) {
    if (now - bucket.start > 120_000) rateBuckets.delete(ip);
  }
}, 60_000).unref();

function sendJSON(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function serveStatic(req, res) {
  let pathname;
  try {
    pathname = decodeURIComponent(new URL(req.url, 'http://local').pathname);
  } catch {
    res.writeHead(400).end('Bad Request');
    return;
  }
  if (pathname === '/') pathname = '/index.html';
  if (pathname === '/favicon.ico') pathname = '/assets/favicon.png';

  const resolved = path.normalize(path.join(ROOT, pathname));
  if (resolved !== ROOT && !resolved.startsWith(`${ROOT}${path.sep}`)) {
    res.writeHead(403).end('Forbidden');
    return;
  }

  fs.stat(resolved, (error, stat) => {
    if (error || !stat.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not Found');
      return;
    }
    const ext = path.extname(resolved).toLowerCase();
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Content-Length': stat.size,
      'Cache-Control': 'no-cache',
      'X-Content-Type-Options': 'nosniff',
    });
    fs.createReadStream(resolved).pipe(res);
  });
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX_REQUEST_BYTES) {
        reject(new Error('请求体过大（上限 24 MB）'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function filterRequestHeaders(pairs) {
  const headers = {};
  for (const entry of pairs || []) {
    if (!Array.isArray(entry) || entry.length < 2) continue;
    const [rawKey, rawValue] = entry;
    const key = String(rawKey || '').trim();
    if (!key) continue;
    const lower = key.toLowerCase();
    if (['host', 'connection', 'content-length', 'transfer-encoding', 'accept-encoding'].includes(lower)) {
      continue;
    }
    headers[key] = String(rawValue ?? '');
  }
  // 明确要求明文，避免服务端压缩后无法按原始字节计数。
  headers['Accept-Encoding'] = 'identity';
  return headers;
}

function decompress(buffer, encodingHeader) {
  const encoding = String(encodingHeader || '').toLowerCase().trim();
  try {
    if (encoding === 'gzip' || encoding === 'x-gzip') return zlib.gunzipSync(buffer);
    if (encoding === 'deflate') return zlib.inflateSync(buffer);
    if (encoding === 'br') return zlib.brotliDecompressSync(buffer);
  } catch {
    return buffer;
  }
  return buffer;
}

function friendlyError(error) {
  const code = error?.code || '';
  switch (code) {
    case 'ENOTFOUND':
      return '域名解析失败（ENOTFOUND），请检查主机名';
    case 'ECONNREFUSED':
      return '连接被拒绝（ECONNREFUSED），目标端口未监听或被拦截';
    case 'ECONNRESET':
      return '连接被重置（ECONNRESET）';
    case 'ETIMEDOUT':
      return '请求超时：目标在设定时间内没有响应';
    case 'CERT_HAS_EXPIRED':
      return '目标站点的 TLS 证书已过期';
    case 'UNABLE_TO_VERIFY_LEAF_SIGNATURE':
    case 'SELF_SIGNED_CERT_IN_CHAIN':
      return '目标站点的 TLS 证书无法验证（自签证书）';
    case 'ERR_INVALID_URL':
      return 'URL 无效';
    default:
      return error?.message || String(error);
  }
}

function requestOnce(url, method, headers, body, { timeoutMs, maxBytes }) {
  return new Promise((resolve, reject) => {
    const transport = url.protocol === 'https:' ? https : http;
    const options = {
      method,
      headers,
      timeout: timeoutMs,
      lookup: PUBLIC_MODE ? safeLookup : undefined,
    };
    const req = transport.request(url, options, (res) => {
      const chunks = [];
      let total = 0;
      let truncated = false;
      let finished = false;

      const done = (buffer) => {
        if (finished) return;
        finished = true;
        const decoded = decompress(buffer, res.headers['content-encoding']);
        const final = decoded.length > maxBytes ? decoded.subarray(0, maxBytes) : decoded;
        // 响应体可能已被解压：去掉与实际字节不符的传输类响应头。
        const headers = rawHeaderPairs(res).filter(
          ([key]) => !['content-encoding', 'content-length', 'transfer-encoding'].includes(key.toLowerCase())
        );
        resolve({
          status: res.statusCode || 0,
          statusText: res.statusMessage || '',
          headers,
          body: final,
          truncated: truncated || decoded.length > maxBytes,
        });
      };

      res.on('data', (chunk) => {
        if (total + chunk.length > maxBytes) {
          const remain = maxBytes - total;
          if (remain > 0) {
            chunks.push(chunk.subarray(0, remain));
            total += remain;
          }
          truncated = true;
          res.destroy();
          done(Buffer.concat(chunks));
          return;
        }
        chunks.push(chunk);
        total += chunk.length;
      });
      res.on('end', () => done(Buffer.concat(chunks)));
      res.on('error', (error) => {
        if (truncated) return;
        reject(error);
      });
    });

    req.on('timeout', () => {
      req.destroy(Object.assign(new Error('请求超时'), { code: 'ETIMEDOUT' }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function rawHeaderPairs(res) {
  const pairs = [];
  const raw = res.rawHeaders || [];
  for (let i = 0; i < raw.length; i += 2) {
    pairs.push([raw[i], raw[i + 1]]);
  }
  return pairs;
}

function headerValue(headers, name) {
  const lower = name.toLowerCase();
  for (const [key, value] of headers) {
    if (String(key).toLowerCase() === lower) return value;
  }
  return null;
}

async function perform(url, method, headers, body, options, redirects = 0) {
  const result = await requestOnce(url, method, headers, body, options);
  const location = headerValue(result.headers, 'location');
  const redirectStatus = [301, 302, 303, 307, 308].includes(result.status);

  if (redirectStatus && location && redirects < MAX_REDIRECTS) {
    let nextUrl;
    try {
      nextUrl = new URL(location, url);
    } catch {
      return result;
    }
    if (nextUrl.protocol !== 'http:' && nextUrl.protocol !== 'https:') return result;

    let nextMethod = method;
    let nextBody = body;
    if (result.status === 303 || ((result.status === 301 || result.status === 302) && !['GET', 'HEAD'].includes(method))) {
      nextMethod = 'GET';
      nextBody = null;
    }
    return perform(nextUrl, nextMethod, headers, nextBody, options, redirects + 1);
  }

  result.finalUrl = url.toString();
  return result;
}

async function handleProxy(req, res) {
  // 防 CSRF：要求自定义头。跨站表单发不出自定义头，跨站 fetch 会触发预检，
  // 而服务端不返回 CORS 预检响应，浏览器会直接拦截。
  if (req.headers['x-devkit-proxy'] !== '1') {
    sendJSON(res, 403, { ok: false, error: '缺少代理调用标识' });
    return;
  }

  const clientIP = req.socket.remoteAddress || 'unknown';
  if (!acquireProxySlot(clientIP)) {
    sendJSON(res, 429, { ok: false, error: '请求过于频繁，请稍后再试（公网部署限流）' });
    return;
  }

  let payload;
  try {
    const raw = await readRequestBody(req);
    payload = JSON.parse(raw.toString('utf8') || '{}');
  } catch (error) {
    releaseProxySlot();
    sendJSON(res, 400, { ok: false, error: `请求解析失败：${error.message}` });
    return;
  }

  let url;
  try {
    url = new URL(String(payload.url || ''));
  } catch {
    releaseProxySlot();
    sendJSON(res, 400, { ok: false, error: 'URL 无效，请填写包含 http:// 或 https:// 的完整地址' });
    return;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    releaseProxySlot();
    sendJSON(res, 400, { ok: false, error: '仅支持 http / https 协议' });
    return;
  }

  if (PUBLIC_MODE) {
    const hostname = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
    const blockedHost =
      hostname === 'localhost' ||
      hostname.endsWith('.localhost') ||
      hostname.endsWith('.local') ||
      isPrivateAddress(hostname);
    if (blockedHost) {
      releaseProxySlot();
      sendJSON(res, 403, { ok: false, error: '目标地址位于本机或内网，公网部署下不允许代理访问' });
      return;
    }
  }

  const method = String(payload.method || 'GET').toUpperCase();
  const headers = filterRequestHeaders(payload.headers);
  const body = payload.bodyText ? Buffer.from(String(payload.bodyText), 'utf8') : null;
  if (body && !headers['Content-Type'] && !headers['content-type']) {
    headers['Content-Type'] = 'text/plain; charset=utf-8';
  }

  const timeoutMs = Math.min(3_600_000, Math.max(1000, Number(payload.timeoutMs) || 30_000));
  const maxBytes = Math.min(20_000_000, Math.max(1024, Number(payload.maxBytes) || MAX_BODY_BYTES));

  const start = Date.now();
  try {
    const result = await perform(url, method, headers, body, { timeoutMs, maxBytes });
    sendJSON(res, 200, {
      ok: true,
      status: result.status,
      statusText: result.statusText,
      headers: result.headers,
      bodyBase64: result.body.toString('base64'),
      truncated: result.truncated,
      durationMs: Math.max(1, Date.now() - start),
      finalUrl: result.finalUrl,
    });
  } catch (error) {
    sendJSON(res, 200, { ok: false, error: friendlyError(error) });
  } finally {
    releaseProxySlot();
  }
}

const server = http.createServer((req, res) => {
  const pathname = (() => {
    try {
      return new URL(req.url, 'http://local').pathname;
    } catch {
      return '';
    }
  })();

  if (pathname === '/api/health') {
    sendJSON(res, 200, { ok: true, proxy: true, version: 1, maxBodyBytes: MAX_BODY_BYTES });
    return;
  }

  if (pathname === '/api/proxy') {
    if (req.method !== 'POST') {
      sendJSON(res, 405, { ok: false, error: '请使用 POST' });
      return;
    }
    handleProxy(req, res);
    return;
  }

  serveStatic(req, res);
});

server.listen(PORT, HOST, () => {
  console.log('');
  console.log('  devkit web');
  console.log(`  地址       http://${HOST}:${PORT}`);
  console.log(
    PUBLIC_MODE
      ? '  代理通道   /api/proxy  （公网模式：已禁用内网目标并开启限流）'
      : '  代理通道   /api/proxy  （本地模式：可访问 localhost / 内网）'
  );
  console.log('');
  console.log('  按 Ctrl+C 停止');
  console.log('');
});

server.on('error', (error) => {
  if (error.code === 'EADDRINUSE') {
    console.error(`端口 ${PORT} 已被占用。可以用 PORT=5174 node server.js 换一个端口。`);
  } else {
    console.error(error);
  }
  process.exit(1);
});
