// 建入站 / 建用户时共用的几个命名小工具。
// 抽出来是因为「中转向导」和「一键 Hy2」两个页面都要用，
// 各写一份的话，改了一处忘另一处就会出现两套命名规则。

// tag / 用户名里只留字母数字下划线、中文、点、横线，其余换成 '-'。
// sing-box 的 tag 会被路由规则、日志、统计到处引用，带空格或引号只会自找麻烦。
export function safeName(raw: string): string {
  const cleaned = (raw || '').trim().replace(/[^\w\u4e00-\u9fa5.-]/g, '-').replace(/^-+|-+$/g, '')
  return cleaned.length > 0 ? cleaned : ''
}

// 当前访问面板用的主机名，作为「节点地址 / SNI」的默认值。
export function currentHost(): string {
  try {
    return window.location.hostname || ''
  } catch {
    return ''
  }
}

// 节点地址只留主机名：误粘的 http(s):// 前缀和 /path 都去掉。
// 端口不动（入口端口由生成逻辑分配，IPv6 的冒号也不能乱切）。
export function normalizeHost(raw: string): string {
  let h = (raw || '').trim()
  if (!h) return ''
  h = h.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '')
  h = h.replace(/\/.*$/, '')
  return h.trim()
}

// 分享链接末尾的 #备注。socks5 链接没有统一标准，但各家导出的都带 fragment。
export function remarkOf(link: string): string {
  const hash = link.indexOf('#')
  if (hash < 0) return ''
  let remark = link.substring(hash + 1)
  try { remark = decodeURIComponent(remark) } catch { /* 不是百分号编码就照原样用 */ }
  return safeName(remark)
}
