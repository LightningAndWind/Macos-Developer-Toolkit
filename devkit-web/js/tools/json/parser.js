/* ==========================================================================
   JSON 解析器（递归下降，对齐 mac 端 JSONParsing.swift）
   相比 JSON.parse，能给出精确行列与尾逗号 / 单引号 / 注释等中文提示。
   ========================================================================== */

export class JSONError extends Error {
  constructor(message, hint, offset, source) {
    super(message);
    this.name = 'JSONError';
    this.hint = hint ?? null;
    this.offset = offset;
    let line = 1;
    let column = 1;
    for (let i = 0; i < offset && i < source.length; i += 1) {
      if (source[i] === '\n') {
        line += 1;
        column = 1;
      } else {
        column += 1;
      }
    }
    this.line = line;
    this.column = column;
  }

  get displayText() {
    return `第 ${this.line} 行 第 ${this.column} 列：${this.message}${this.hint ? `（${this.hint}）` : ''}`;
  }
}

class Scanner {
  constructor(source) {
    this.source = source;
    this.index = 0;
  }

  get atEnd() {
    return this.index >= this.source.length;
  }

  get peek() {
    return this.index < this.source.length ? this.source[this.index] : null;
  }

  consume() {
    this.index += 1;
  }

  skipWhitespace() {
    while (this.peek === ' ' || this.peek === '\t' || this.peek === '\n' || this.peek === '\r') {
      this.consume();
    }
  }

  error(message, hint = null) {
    return new JSONError(message, hint, this.index, this.source);
  }

  parseDocument() {
    this.skipWhitespace();
    if (this.atEnd) throw this.error('文档内容为空', '请输入合法的 JSON');
    const value = this.parseValue();
    this.skipWhitespace();
    if (!this.atEnd) throw this.error('存在多余的字符', 'JSON 只能有一个根值，检查是否漏了括号或逗号');
    return value;
  }

  parseValue() {
    this.skipWhitespace();
    const ch = this.peek;
    if (ch === null) throw this.error('值缺失', '到达文档末尾但未找到值');
    switch (ch) {
      case '{': return this.parseObject();
      case '[': return this.parseArray();
      case '"': return { type: 'string', value: this.parseString() };
      case 't': this.expectLiteral('true'); return { type: 'bool', value: true };
      case 'f': this.expectLiteral('false'); return { type: 'bool', value: false };
      case 'n': this.expectLiteral('null'); return { type: 'null' };
      case "'": throw this.error('字符串必须使用双引号', `把 ' 改成 "…"`);
      case '/': throw this.error('不支持注释', '标准 JSON 不允许 // 或 /* */ 注释，请删除');
      default:
        if (ch === '-' || (ch >= '0' && ch <= '9')) return this.parseNumber();
        throw this.error(`意外的字符 '${ch}'`, '此处应是一个值');
    }
  }

  parseObject() {
    this.consume();
    const members = [];
    this.skipWhitespace();
    if (this.peek === '}') {
      this.consume();
      return { type: 'object', members };
    }
    while (true) {
      this.skipWhitespace();
      if (this.peek !== '"') {
        if (this.peek === '}') throw this.error('对象存在尾随逗号', '删除最后一个成员后的逗号');
        throw this.error('对象键名必须是字符串', '键名需用 "…" 包裹');
      }
      const key = this.parseString();
      this.skipWhitespace();
      if (this.peek !== ':') throw this.error("键名后缺少冒号 ':'", '写成 "键": 值');
      this.consume();
      const value = this.parseValue();
      members.push({ key, value });

      this.skipWhitespace();
      if (this.peek === ',') {
        this.consume();
        this.skipWhitespace();
        if (this.peek === '}') throw this.error('对象存在尾随逗号', '删除最后一个成员后的逗号');
      } else if (this.peek === '}') {
        this.consume();
        return { type: 'object', members };
      } else {
        throw this.error('对象成员后缺少逗号或右花括号', "检查 ',' 或 '}' 是否遗漏");
      }
    }
  }

  parseArray() {
    this.consume();
    const values = [];
    this.skipWhitespace();
    if (this.peek === ']') {
      this.consume();
      return { type: 'array', values };
    }
    while (true) {
      values.push(this.parseValue());
      this.skipWhitespace();
      if (this.peek === ',') {
        this.consume();
        this.skipWhitespace();
        if (this.peek === ']') throw this.error('数组存在尾随逗号', '删除最后一个元素后的逗号');
      } else if (this.peek === ']') {
        this.consume();
        return { type: 'array', values };
      } else {
        throw this.error('数组元素后缺少逗号或右方括号', "检查 ',' 或 ']' 是否遗漏");
      }
    }
  }

  parseString() {
    if (this.peek !== '"') throw this.error('字符串缺少起始双引号');
    this.consume();
    let result = '';
    while (true) {
      const ch = this.peek;
      if (ch === null) throw this.error('字符串未闭合', '缺少结束的 "');
      if (ch === '"') {
        this.consume();
        return result;
      }
      if (ch === '\\') {
        this.consume();
        const esc = this.peek;
        if (esc === null) throw this.error('转义字符后缺少内容');
        this.consume();
        switch (esc) {
          case '"': result += '"'; break;
          case '\\': result += '\\'; break;
          case '/': result += '/'; break;
          case 'b': result += '\b'; break;
          case 'f': result += '\f'; break;
          case 'n': result += '\n'; break;
          case 'r': result += '\r'; break;
          case 't': result += '\t'; break;
          case 'u': result += this.parseUnicodeEscape(); break;
          default: throw this.error(`非法转义字符 '\\${esc}'`);
        }
      } else if (ch === '\n') {
        throw this.error('字符串内出现裸换行', '换行应转义为 \\n 或用引号包裹整段');
      } else {
        result += ch;
        this.consume();
      }
    }
  }

  parseUnicodeEscape() {
    const code = this.parseHex4();
    if (code >= 0xd800 && code <= 0xdbff && this.peek === '\\' && this.source[this.index + 1] === 'u') {
      this.consume();
      this.consume();
      const low = this.parseHex4();
      if (low >= 0xdc00 && low <= 0xdfff) {
        return String.fromCodePoint(0x10000 + (code - 0xd800) * 0x400 + (low - 0xdc00));
      }
      throw this.error('非法的 UTF-16 代理对');
    }
    try {
      return String.fromCodePoint(code);
    } catch {
      throw this.error('非法的 Unicode 码点');
    }
  }

  parseHex4() {
    let value = 0;
    for (let i = 0; i < 4; i += 1) {
      const ch = this.peek;
      if (ch === null || !/[0-9a-fA-F]/.test(ch)) throw this.error('\\u 需要 4 位十六进制数字');
      value = value * 16 + parseInt(ch, 16);
      this.consume();
    }
    return value;
  }

  parseNumber() {
    const start = this.index;
    if (this.peek === '-') this.consume();
    if (this.peek === null) throw this.error('负号后缺少数字');

    if (this.peek === '0') {
      this.consume();
    } else if (this.peek >= '0' && this.peek <= '9') {
      while (this.peek >= '0' && this.peek <= '9') this.consume();
    } else {
      throw this.error('数字格式非法', `数字不能以 '${this.peek ?? '?'}' 开头`);
    }

    if (this.peek === '.') {
      this.consume();
      if (!(this.peek >= '0' && this.peek <= '9')) throw this.error('小数点后缺少数字');
      while (this.peek >= '0' && this.peek <= '9') this.consume();
    }

    if (this.peek === 'e' || this.peek === 'E') {
      this.consume();
      if (this.peek === '+' || this.peek === '-') this.consume();
      if (!(this.peek >= '0' && this.peek <= '9')) throw this.error('指数部分缺少数字');
      while (this.peek >= '0' && this.peek <= '9') this.consume();
    }

    return { type: 'number', raw: this.source.slice(start, this.index) };
  }

  expectLiteral(literal) {
    for (const expected of literal) {
      if (this.peek !== expected) throw this.error('意外的关键字', `是否想写 ${literal}？`);
      this.consume();
    }
  }
}

export function parseJSON(text) {
  const source = String(text ?? '');
  try {
    return { ok: true, value: new Scanner(source).parseDocument() };
  } catch (error) {
    if (error instanceof JSONError) return { ok: false, error };
    return { ok: false, error: new JSONError('解析失败', null, source.length, source) };
  }
}

/* — 序列化 — */

export const INDENTS = {
  spaces2: { unit: '  ', label: '2 空格' },
  spaces4: { unit: '    ', label: '4 空格' },
  tab: { unit: '\t', label: 'Tab' },
};

export function encodeJSONString(text) {
  let out = '"';
  for (const char of String(text)) {
    const code = char.codePointAt(0);
    switch (char) {
      case '"': out += '\\"'; break;
      case '\\': out += '\\\\'; break;
      case '\n': out += '\\n'; break;
      case '\r': out += '\\r'; break;
      case '\t': out += '\\t'; break;
      case '\b': out += '\\b'; break;
      case '\f': out += '\\f'; break;
      default:
        if (code < 0x20) out += `\\u${code.toString(16).toUpperCase().padStart(4, '0')}`;
        else out += char;
    }
  }
  return `${out}"`;
}

function writeValue(value, level, unit, out) {
  switch (value.type) {
    case 'null': out.text += 'null'; break;
    case 'bool': out.text += value.value ? 'true' : 'false'; break;
    case 'number': out.text += value.raw; break;
    case 'string': out.text += encodeJSONString(value.value); break;
    case 'array': {
      out.text += '[';
      if (!value.values.length) {
        out.text += ']';
        return;
      }
      const pad = unit ? unit.repeat(level + 1) : '';
      const closePad = unit ? unit.repeat(level) : '';
      const newline = unit ? '\n' : '';
      value.values.forEach((item, index) => {
        if (index > 0) out.text += ',';
        out.text += newline + pad;
        writeValue(item, level + 1, unit, out);
      });
      out.text += newline + closePad + ']';
      break;
    }
    case 'object': {
      out.text += '{';
      if (!value.members.length) {
        out.text += '}';
        return;
      }
      const pad = unit ? unit.repeat(level + 1) : '';
      const closePad = unit ? unit.repeat(level) : '';
      const newline = unit ? '\n' : '';
      value.members.forEach((member, index) => {
        if (index > 0) out.text += ',';
        out.text += newline + pad + encodeJSONString(member.key) + ':';
        if (unit) out.text += ' ';
        writeValue(member.value, level + 1, unit, out);
      });
      out.text += newline + closePad + '}';
      break;
    }
    default:
      break;
  }
}

export function prettyJSON(value, indentKey = 'spaces2') {
  const unit = INDENTS[indentKey]?.unit ?? '  ';
  const out = { text: '' };
  writeValue(value, 0, unit, out);
  return out.text;
}

export function minifyJSON(value) {
  const out = { text: '' };
  writeValue(value, 0, null, out);
  return out.text;
}

/* — 统计 — */

export function jsonStats(value) {
  const stats = {
    nodeCount: 0,
    maxDepth: 0,
    objectCount: 0,
    arrayCount: 0,
    stringCount: 0,
    numberCount: 0,
    boolCount: 0,
    nullCount: 0,
  };

  const walk = (node) => {
    let nodes = 1;
    let depth = 0;
    switch (node.type) {
      case 'object':
        stats.objectCount += 1;
        for (const member of node.members) {
          const child = walk(member.value);
          nodes += child.nodes;
          depth = Math.max(depth, child.depth + 1);
        }
        break;
      case 'array':
        stats.arrayCount += 1;
        for (const item of node.values) {
          const child = walk(item);
          nodes += child.nodes;
          depth = Math.max(depth, child.depth + 1);
        }
        break;
      case 'string': stats.stringCount += 1; break;
      case 'number': stats.numberCount += 1; break;
      case 'bool': stats.boolCount += 1; break;
      case 'null': stats.nullCount += 1; break;
      default: break;
    }
    return { nodes, depth };
  };

  const total = walk(value);
  stats.nodeCount = total.nodes;
  stats.maxDepth = total.depth;
  return stats;
}

export function sortKeys(value, ascending = true, recursive = true) {
  if (value.type === 'object') {
    const members = [...value.members].sort((a, b) => {
      const compare = a.key.localeCompare(b.key, 'zh-Hans-CN', { sensitivity: 'base' });
      return ascending ? compare : -compare;
    });
    return {
      type: 'object',
      members: members.map((member) => ({
        key: member.key,
        value: recursive ? sortKeys(member.value, ascending, true) : member.value,
      })),
    };
  }
  if (value.type === 'array') {
    if (!recursive) return value;
    return { type: 'array', values: value.values.map((item) => sortKeys(item, ascending, true)) };
  }
  return value;
}


export function scalarDisplay(value) {
  switch (value?.type) {
    case 'string': return `"${value.value.replaceAll('\\', '\\\\').replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t')}"`;
    case 'number': return value.raw;
    case 'bool': return value.value ? 'true' : 'false';
    case 'null': return 'null';
    case 'object': return `{${value.members.length}}`;
    case 'array': return `[${value.values.length}]`;
    default: return '';
  }
}

export function childCount(value) {
  if (value?.type === 'object') return value.members.length;
  if (value?.type === 'array') return value.values.length;
  return 0;
}
