/* ==========================================================================
   HTTP 历史记录（IndexedDB）
   响应体单独存一份，避免撑爆 localStorage；单条上限 256 KB。
   ========================================================================== */

import { uid } from '../../ui/dom.js';

const DB_NAME = 'devkit-web';
const DB_VERSION = 1;
const STORE = 'http-history';
const MAX_RECORDS = 300;
export const HISTORY_BODY_LIMIT = 256 * 1024;

let dbPromise = null;

function openDB() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: 'id' });
        store.createIndex('at', 'at');
        store.createIndex('savedRequestId', 'savedRequestId');
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  return dbPromise;
}

function tx(mode) {
  return openDB().then((db) => db.transaction(STORE, mode).objectStore(STORE));
}

function requestToPromise(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export function bytesToBase64(bytes) {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function base64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export const historyStore = {
  async add({ request, response, error, savedRequestId }) {
    const at = Date.now();
    let bodyBytes = response?.bodyBytes ?? new Uint8Array();
    let truncated = Boolean(response?.isTruncated);
    if (bodyBytes.length > HISTORY_BODY_LIMIT) {
      bodyBytes = bodyBytes.subarray(0, HISTORY_BODY_LIMIT);
      truncated = true;
    }
    const record = {
      id: uid('hist'),
      at,
      method: request.method,
      url: request.urlString,
      request: JSON.parse(JSON.stringify(request)),
      savedRequestId: savedRequestId ?? null,
      response: response
        ? {
            status: response.status,
            statusText: response.statusText || '',
            durationMs: response.durationMs,
            headers: response.headers,
            contentType: response.contentType || '',
            bodyBase64: bytesToBase64(bodyBytes),
            sizeBytes: bodyBytes.length,
            isTruncated: truncated,
            viaProxy: Boolean(response.viaProxy),
          }
        : null,
      error: error || null,
    };

    const store = await tx('readwrite');
    await requestToPromise(store.put(record));
    await this.trim();
    return record;
  },

  async trim() {
    const store = await tx('readwrite');
    const count = await requestToPromise(store.count());
    if (count <= MAX_RECORDS) return;
    let toDelete = count - MAX_RECORDS;
    const cursorRequest = store.index('at').openCursor();
    await new Promise((resolve, reject) => {
      cursorRequest.onsuccess = () => {
        const cursor = cursorRequest.result;
        if (!cursor || toDelete <= 0) return resolve();
        cursor.delete();
        toDelete -= 1;
        cursor.continue();
      };
      cursorRequest.onerror = () => reject(cursorRequest.error);
    });
  },

  async recent(limit = 300) {
    const store = await tx('readonly');
    const index = store.index('at');
    const records = [];
    await new Promise((resolve, reject) => {
      const cursorRequest = index.openCursor(null, 'prev');
      cursorRequest.onsuccess = () => {
        const cursor = cursorRequest.result;
        if (!cursor || records.length >= limit) return resolve();
        records.push(cursor.value);
        cursor.continue();
      };
      cursorRequest.onerror = () => reject(cursorRequest.error);
    });
    return records;
  },

  async search(query, limit = 300) {
    const all = await this.recent(limit);
    const q = String(query || '').trim().toLowerCase();
    if (!q) return all;
    return all.filter(
      (record) =>
        record.url.toLowerCase().includes(q) ||
        String(record.method).toLowerCase().includes(q) ||
        String(record.response?.status ?? '').includes(q)
    );
  },

  async remove(id) {
    const store = await tx('readwrite');
    await requestToPromise(store.delete(id));
  },

  async clear() {
    const store = await tx('readwrite');
    await requestToPromise(store.clear());
  },

  async bulkPut(records) {
    if (!Array.isArray(records) || !records.length) return;
    const store = await tx('readwrite');
    await Promise.all(
      records
        .filter((record) => record && record.id && record.request)
        .map((record) => requestToPromise(store.put(record)))
    );
  },

  async count() {
    const store = await tx('readonly');
    return requestToPromise(store.count());
  },

  async removeBySavedRequest(savedRequestId) {
    const store = await tx('readwrite');
    const index = store.index('savedRequestId');
    // 该索引可能不存在（旧库），退化为全表扫描。
    try {
      const ids = await new Promise((resolve, reject) => {
        const found = [];
        const cursorRequest = index.openCursor(IDBKeyRange.only(savedRequestId));
        cursorRequest.onsuccess = () => {
          const cursor = cursorRequest.result;
          if (!cursor) return resolve(found);
          found.push(cursor.primaryKey);
          cursor.continue();
        };
        cursorRequest.onerror = () => reject(cursorRequest.error);
      });
      await Promise.all(ids.map((id) => requestToPromise(store.delete(id))));
    } catch {
      const all = await requestToPromise(store.getAll());
      await Promise.all(
        all
          .filter((record) => record.savedRequestId === savedRequestId)
          .map((record) => requestToPromise(store.delete(record.id)))
      );
    }
  },
};
