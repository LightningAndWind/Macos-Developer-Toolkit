/* ==========================================================================
   浮层：模态框、菜单、气泡、Toast
   ========================================================================== */

import { h, icon, clear } from './dom.js';

const stack = [];

function pushOverlay(close) {
  stack.push(close);
}

function popOverlay(close) {
  const index = stack.lastIndexOf(close);
  if (index >= 0) stack.splice(index, 1);
}

document.addEventListener(
  'keydown',
  (event) => {
    if (event.key !== 'Escape' || stack.length === 0) return;
    const close = stack[stack.length - 1];
    event.preventDefault();
    event.stopPropagation();
    close();
  },
  true
);

/* — 模态框 — */

export function openModal({ title, body, footer, width = 460, className = '', dismissible = true, onClose }) {
  const overlay = h('div', { class: 'overlay' });
  const modal = h('div', { class: `modal ${className}`.trim(), style: width ? { width: `${width}px` } : null });

  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    popOverlay(close);
    overlay.remove();
    document.removeEventListener('keydown', onKey);
    onClose?.();
  };
  const onKey = (event) => {
    if (event.key === 'Escape' && dismissible) {
      event.preventDefault();
      event.stopPropagation();
      close();
    }
  };

  const head = h(
    'div',
    { class: 'modal-head' },
    h('div', { class: 'modal-title' }, title),
    dismissible
      ? h('button', { class: 'modal-close', title: '关闭', onclick: close }, icon('x', 13))
      : null
  );

  const bodyEl = h('div', { class: 'modal-body' }, body);
  modal.append(head, bodyEl);
  if (footer) {
    const foot = h('div', { class: 'modal-foot' }, footer);
    modal.append(foot);
  }

  if (dismissible) {
    overlay.addEventListener('pointerdown', (event) => {
      if (event.target === overlay) close();
    });
  }
  document.addEventListener('keydown', onKey);
  overlay.append(modal);
  document.getElementById('overlay-root').append(overlay);
  pushOverlay(close);

  requestAnimationFrame(() => {
    const focusable = modal.querySelector('input, textarea, select, button.primary');
    focusable?.focus();
    if (focusable instanceof HTMLInputElement) focusable.select?.();
  });

  return { close, el: modal, body: bodyEl, overlay };
}

/* — 菜单 — */

export function openMenu(anchor, items, { align = 'left', width = 0, at = null } = {}) {
  const menu = h('div', { class: 'popover', role: 'menu' });
  let closed = false;

  const close = () => {
    if (closed) return;
    closed = true;
    document.removeEventListener('pointerdown', onPointerDown, true);
    document.removeEventListener('scroll', close, true);
    window.removeEventListener('resize', close);
    popOverlay(close);
    menu.remove();
  };

  const onPointerDown = (event) => {
    if (!menu.contains(event.target) && !anchor.contains?.(event.target)) close();
  };

  for (const item of items) {
    if (!item) continue;
    if (item.sep) {
      menu.append(h('div', { class: 'menu-sep' }));
      continue;
    }
    if (item.heading) {
      menu.append(h('div', { class: 'menu-label' }, item.heading));
      continue;
    }
    const button = h(
      'button',
      {
        class: `menu-item ${item.danger ? 'danger' : ''}`.trim(),
        disabled: item.disabled,
        onclick: () => {
          close();
          item.run?.();
        },
      },
      item.icon ? icon(item.icon, 14, 'menu-icon') : item.dot
        ? h('span', { class: 'menu-dot', style: { background: item.dot } })
        : null,
      h('span', null, item.label),
      item.checked ? icon('check', 13, 'menu-check') : null
    );
    menu.append(button);
  }

  if (width) menu.style.width = `${width}px`;
  document.body.append(menu);

  const rect = anchor.getBoundingClientRect();
  const menuRect = menu.getBoundingClientRect();
  let left = at ? at.x : align === 'right' ? rect.right - menuRect.width : rect.left;
  let top = at ? at.y : rect.bottom + 5;
  left = Math.max(8, Math.min(left, window.innerWidth - menuRect.width - 8));
  if (top + menuRect.height > window.innerHeight - 8) {
    top = at
      ? Math.max(8, at.y - menuRect.height)
      : Math.max(8, rect.top - menuRect.height - 5);
  }
  menu.style.left = `${Math.round(left)}px`;
  menu.style.top = `${Math.round(top)}px`;

  setTimeout(() => {
    document.addEventListener('pointerdown', onPointerDown, true);
    document.addEventListener('scroll', close, true);
    window.addEventListener('resize', close);
  }, 0);
  pushOverlay(close);
  return { close, el: menu };
}

/* — 气泡 — */

export function openPopover(anchor, content, { align = 'left', className = '', width = 0 } = {}) {
  const pop = h('div', { class: `popover pad ${className}`.trim() }, content);
  let closed = false;

  const close = () => {
    if (closed) return;
    closed = true;
    document.removeEventListener('pointerdown', onPointerDown, true);
    window.removeEventListener('resize', close);
    popOverlay(close);
    pop.remove();
  };

  const onPointerDown = (event) => {
    if (!pop.contains(event.target) && !anchor.contains?.(event.target)) close();
  };

  if (width) pop.style.width = `${width}px`;
  document.body.append(pop);

  const rect = anchor.getBoundingClientRect();
  const popRect = pop.getBoundingClientRect();
  let left = align === 'right' ? rect.right - popRect.width : rect.left;
  let top = rect.bottom + 6;
  left = Math.max(8, Math.min(left, window.innerWidth - popRect.width - 8));
  if (top + popRect.height > window.innerHeight - 8) {
    top = Math.max(8, rect.top - popRect.height - 6);
  }
  pop.style.left = `${Math.round(left)}px`;
  pop.style.top = `${Math.round(top)}px`;

  setTimeout(() => {
    document.addEventListener('pointerdown', onPointerDown, true);
    window.addEventListener('resize', close);
  }, 0);
  pushOverlay(close);
  return { close, el: pop };
}

/* — Toast — */

export function toast(message, kind = '', iconName = null) {
  const root = document.getElementById('toast-root');
  const iconName2 = iconName ?? (kind === 'success' ? 'checkCircle' : kind === 'error' ? 'alert' : kind === 'warn' ? 'alert' : 'info');
  const el = h('div', { class: `toast ${kind}`.trim() }, icon(iconName2, 14), h('span', null, message));
  root.append(el);
  setTimeout(() => {
    el.classList.add('is-out');
    setTimeout(() => el.remove(), 200);
  }, 3800);
}

/* — 确认框 — */

export function confirmDialog({ title, message, confirmText = '确定', cancelText = '取消', danger = false }) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    const modal = openModal({
      title,
      width: 380,
      body: h('div', { style: { lineHeight: '1.6', color: 'var(--text-2)' } }, message),
      footer: [
        h('div', { class: 'spacer' }),
        h('button', { class: 'btn', onclick: () => { finish(false); modal.close(); } }, cancelText),
        h(
          'button',
          {
            class: `btn ${danger ? 'danger' : 'primary'}`,
            onclick: () => {
              finish(true);
              modal.close();
            },
          },
          confirmText
        ),
      ],
      onClose: () => finish(false),
    });
  });
}

/* — 单行输入框 — */

export function promptDialog({ title, label, value = '', placeholder = '', confirmText = '确定' }) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    const input = h('input', { class: 'input', value, placeholder });
    const submit = () => {
      const text = input.value.trim();
      if (!text) {
        input.focus();
        return;
      }
      finish(text);
      modal.close();
    };
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        event.preventDefault();
        submit();
      }
    });
    const modal = openModal({
      title,
      width: 380,
      body: h('div', { class: 'field', style: { marginBottom: '0' } }, label ? h('label', null, label) : null, input),
      footer: [
        h('div', { class: 'spacer' }),
        h('button', { class: 'btn', onclick: () => { finish(null); modal.close(); } }, '取消'),
        h('button', { class: 'btn primary', onclick: submit }, confirmText),
      ],
      onClose: () => finish(null),
    });
    requestAnimationFrame(() => {
      input.focus();
      input.select();
    });
  });
}

/* — 页面内临时反馈 — */

export function flashButton(button, doneLabel, iconName = 'check') {
  const original = Array.from(button.childNodes);
  const originalClass = button.className;
  clear(button);
  button.append(icon(iconName, 14), h('span', null, doneLabel));
  button.classList.add('ok');
  setTimeout(() => {
    clear(button);
    button.append(...original);
    button.className = originalClass;
  }, 1400);
}
