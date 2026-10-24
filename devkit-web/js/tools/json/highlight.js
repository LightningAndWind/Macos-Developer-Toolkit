/* ==========================================================================
   JSON 语法高亮：把纯文本切成 token 并输出安全的 HTML。
   ========================================================================== */

import { escapeHTML } from '../../ui/dom.js';

const TOKEN = /("(?:\\.|[^"\\])*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b/g;

function punctuation(text) {
  return escapeHTML(text).replace(/([{}[\],:])/g, '<span class="tok-punc">$1</span>');
}

export function highlightJSON(text) {
  const source = String(text ?? '');
  let out = '';
  let last = 0;
  TOKEN.lastIndex = 0;
  let match;
  while ((match = TOKEN.exec(source))) {
    out += punctuation(source.slice(last, match.index));
    if (match[1] !== undefined) {
      const isKey = Boolean(match[2]);
      out += `<span class="${isKey ? 'tok-key' : 'tok-str'}">${escapeHTML(match[1])}</span>`;
      if (match[2]) {
        out += `<span class="tok-punc">:</span>${escapeHTML(match[2].replace(':', ''))}`;
      }
    } else if (match[3] !== undefined) {
      out += `<span class="tok-num">${escapeHTML(match[3])}</span>`;
    } else if (match[4] !== undefined) {
      out += `<span class="tok-lit">${escapeHTML(match[4])}</span>`;
    }
    last = TOKEN.lastIndex;
  }
  out += punctuation(source.slice(last));
  return out;
}

export function plainHighlight(text) {
  return escapeHTML(text);
}

