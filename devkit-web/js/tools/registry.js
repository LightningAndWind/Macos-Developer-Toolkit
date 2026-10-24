/* ==========================================================================
   工具注册表：新增工具只需在此加一行
   ========================================================================== */

import { defaultHTTPData, defaultJSONData } from '../store.js';
import { createHTTPView } from './http/view.js';
import { createJSONView } from './json/view.js';

export const TOOLS = [
  {
    id: 'tool.http',
    title: 'HTTP 请求',
    subtitle: '构造并发送 HTTP 请求，查看响应与历史记录。',
    category: '网络',
    icon: 'arrows',
    desktopOnly: false,
    createData: defaultHTTPData,
    createView: createHTTPView,
    chooser: true,
  },
  {
    id: 'tool.ssh',
    title: 'SSH 终端',
    subtitle: '本地终端与 SSH 会话，连接配置按文件夹归类管理。',
    category: '终端',
    icon: 'terminal',
    desktopOnly: true,
  },
  {
    id: 'tool.sftp',
    title: 'SFTP 传输',
    subtitle: '左右两区各连一台主机，多选文件双向互传。',
    category: '终端',
    icon: 'sftp',
    desktopOnly: true,
  },
  {
    id: 'tool.json',
    title: 'JSON 工具',
    subtitle: '文本 / 树形双视图编辑、格式化、校验、键排序。',
    category: '数据',
    icon: 'braces',
    desktopOnly: false,
    createData: defaultJSONData,
    createView: createJSONView,
  },
  {
    id: 'tool.git',
    title: 'Git 管理',
    subtitle: '仓库按文件夹归类登记，绑定 SSH 密钥并执行 git 操作。',
    category: '实用工具',
    icon: 'git',
    desktopOnly: true,
  },
];

export const CATEGORY_ORDER = ['网络', '终端', '数据', '实用工具'];

export function toolById(id) {
  return TOOLS.find((tool) => tool.id === id) ?? null;
}

export function desktopReason(toolId) {
  switch (toolId) {
    case 'tool.ssh':
      return {
        title: '浏览器无法打开本地 shell',
        body: 'SSH 终端需要创建原始 TCP 连接、驱动 PTY 并保存私钥口令。浏览器沙箱只提供 HTTPS / WebSocket，无法直接连接 22 端口，也不能读写本机文件系统。',
      };
    case 'tool.sftp':
      return {
        title: 'SFTP 依赖本地文件系统',
        body: 'SFTP 需要在两台主机之间递归传输文件，并直接操作本机目录。网页无法获得这种级别的文件访问权限，因此该工具保留在桌面端。',
      };
    case 'tool.git':
      return {
        title: 'Git 操作需要真实的仓库目录',
        body: '分支切换、暂存、提交与冲突解决都要读写工作区并调用 git 可执行文件。浏览器没有工作区概念，无法安全地模拟这些操作。',
      };
    default:
      return { title: '桌面版专属', body: '该工具需要本机系统能力，暂不在网页版提供。' };
  }
}
