import { bootApp } from './shell.js';

try {
  const app = bootApp();
  window.__devkit = app;
} catch (error) {
  console.error('[devkit] 启动失败', error);
  const root = document.getElementById('content');
  if (root) {
    root.innerHTML = `
      <div style="padding:40px;font-family:-apple-system,sans-serif;color:#444">
        <h2 style="margin:0 0 8px">启动失败</h2>
        <p style="color:#777;font-size:13px">请打开开发者工具查看错误详情。若通过 file:// 打开，请改用本地服务：</p>
        <pre style="background:#f4f5f7;padding:12px;border-radius:8px;font-size:12px">node server.js</pre>
        <pre style="color:#b02a30;font-size:11px;white-space:pre-wrap">${String(error?.stack || error)}</pre>
      </div>`;
  }
}
