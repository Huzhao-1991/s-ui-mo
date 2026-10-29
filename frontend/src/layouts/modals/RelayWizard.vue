<template>
  <!-- ======================================================================
    添加中转向导（RelayWizard）
    --------------------------------------------------------------------
    两种建法，用顶部开关切换：

    A. 接入已有入站（attach）
       解析一条「落地节点分享链接」 -> 得到一个 sing-box 出站对象
         - socks5 链接在前端直接解析（socks5:// 或 IP:端口[:用户:密码]）
         - 其它协议（vless/vmess/trojan/ss/hysteria2/tuic...）调后端
           api/linkConvert 转换（与出站页「从链接导入」同一接口）
       然后往 config.route.rules 追加规则，把「已有入站 + 已有用户 + 新出站」
       关联起来。规则按用户拆开，每个用户一条：
         {inbound:[入口入站], auth_user:[用户名], action:'route', outbound:tag}
       这样一个用户在「路由列表」里就是一条看得见、改得动的规则。

    B. 自动建站（provision）
       一次粘贴多行落地链接，每行一条，逐条生成一整套：
         入站（协议见下）、用户（随机凭据）、出站（该行的 socks5 落地）、
         规则 {inbound:[新入站], auth_user:[新用户], action:'route', outbound:新出站}
       N 行链接 = N 个入站 + N×每节点用户数 个用户 + N 个出站 + N×用户数 条规则。

       入口协议（form.protocol）三种：
         vless    —— VLESS + Reality，客户端从公网连进来这一段值得真加密（旧行为）
         hysteria2 —— Hysteria2（QUIC/UDP）+ TLS，落地仍是 socks5 住宅 IP。
                      这是「住宅 IP 中转」的常见形态：客户端用 hy2 连本机，
                      本机再把流量交给住宅代理出去。
         anytls   —— AnyTLS（TCP/TLS）+ 住宅 socks5，与 hy2 同一套粘贴 / 地址 /
                      SNI / 证书 / 逐行预览逻辑；凭据是密码（sing-anytls 认密码，
                      不用 uuid），没有 salamander 混淆，alpn 留空不写死。
         两种 TLS 入口都可以复用一份带服务端证书的配置，或现场自签一份
         （自签时客户端侧带 insecure，链接里会自动出现 insecure=1）。
         节点地址留空则用当前访问面板的域名/IP 拼链接，
         填了就写进入站的 addrs（链接里就用这个主机名）。

    两种模式都只在最后保存一次 config —— 后端只有 config 这一个 object 会
    重启核心，把规则攒到最后一起写，N 个节点也只重启一次。

    建完之后把新建的入口入站 tag 通过 created 事件交给中转页，
    由它打开「节点链接」弹窗（RelayLinks.vue）把 anytls / hysteria2 链接摊出来。

    后端无需任何新接口，全部复用：
      - api/save       object=inbounds / clients / outbounds / tls / config
      - api/keypairs   ?k=reality（Reality 密钥对）/ ?k=tls（自签证书）
      - api/linkConvert（分享链接 -> 出站对象）
      - api/checkOutbound ?tag=（对落地出站做一次连通性测速）
    ====================================================================== -->
  <v-dialog transition="dialog-bottom-transition" width="680">
    <v-card class="rounded-lg" :loading="loading">
      <v-card-title>{{ $t('relay.title') }}</v-card-title>
      <v-divider />
      <v-card-text>
        <v-container style="padding: 0;">
          <p style="font-size: 0.85rem; opacity: 0.8; margin-bottom: 12px;">{{ $t('relay.desc') }}</p>

          <!-- 建法开关。粘贴多行时会自动切到「自动建站」（见 links 的 watch） -->
          <v-btn-toggle
            v-model="mode"
            mandatory
            divided
            density="compact"
            style="margin-bottom: 14px;"
          >
            <v-btn value="attach" size="small">{{ $t('relay.modeAttach') }}</v-btn>
            <v-btn value="provision" size="small">{{ $t('relay.modeProvision') }}</v-btn>
          </v-btn-toggle>

          <v-row>
            <!-- 入口协议：只影响「自动建站」。attach 模式不动已有入站，没有这一项 -->
            <v-col cols="12" v-if="mode == 'provision'">
              <v-btn-toggle
                v-model="form.protocol"
                mandatory
                divided
                density="compact"
                variant="outlined"
                color="primary"
              >
                <v-btn value="vless" size="small">{{ $t('relay.protoVless') }}</v-btn>
                <v-btn value="hysteria2" size="small">{{ $t('relay.protoHy2') }}</v-btn>
                <v-btn value="anytls" size="small">{{ $t('relay.protoAnytls') }}</v-btn>
              </v-btn-toggle>
              <p style="font-size: 0.78rem; opacity: 0.75; margin-top: 6px;">
                {{ isHy2 ? $t('relay.protoHintHy2') : (isAnytls ? $t('relay.protoHintAnytls') : $t('relay.protoHintVless')) }}
              </p>
            </v-col>

            <v-col cols="12">
              <!-- 落地节点分享链接。attach 模式只用一行；provision 模式每行一条。
                   socks 模式（hy2/anytls）下这里是「住宅 socks5 列表」，只收 socks5 写法。 -->
              <v-textarea
                :label="linkLabel"
                :hint="linkHint"
                persistent-hint
                v-model="form.link"
                :rows="mode == 'provision' ? 5 : 2"
                auto-grow
              />
              <p v-if="mode == 'provision' && links.length > 0" style="font-size: 0.8rem; opacity: 0.75; margin-top: 6px;">
                {{ $t('relay.bulkCount', { n: links.length }) }}
              </p>
              <!-- 逐行解析预览：socks 模式（hy2/anytls）只收 socks5，
                   写错的行当场标红，不用等建到一半才发现。 -->
              <v-card
                v-if="mode == 'provision' && isSocks && links.length > 0"
                variant="outlined"
                class="rounded-lg"
                style="margin-top: 8px; max-height: 170px; overflow: auto;"
              >
                <v-list density="compact">
                  <v-list-item v-for="p in bulkPreview" :key="p.index">
                    <template #prepend>
                      <v-icon
                        :color="p.ok ? 'success' : 'error'"
                        :icon="p.ok ? 'mdi-check-circle' : 'mdi-alert-circle'"
                        size="small"
                      />
                    </template>
                    <v-list-item-title style="font-size: 0.8rem; font-family: monospace;">{{ p.index }}. {{ p.text }}</v-list-item-title>
                    <v-list-item-subtitle style="font-size: 0.72rem;">{{ p.detail }}</v-list-item-subtitle>
                  </v-list-item>
                </v-list>
              </v-card>
            </v-col>

            <!-- ---------------- attach：接入已有入站 ---------------- -->
            <template v-if="mode == 'attach'">
              <v-col cols="12" sm="6">
                <v-text-field
                  :label="$t('relay.name')"
                  v-model="form.name"
                  hide-details
                />
              </v-col>
              <v-col cols="12">
                <!-- 入口入站：多选。只有选中的入站流量会走落地，
                     未选中的保持直连（这是刻意设计，见 reset() 注释） -->
                <v-select
                  :label="$t('relay.entry')"
                  :hint="$t('relay.entryHint')"
                  persistent-hint
                  :items="inboundOptions"
                  v-model="form.inbounds"
                  multiple
                  chips
                />
              </v-col>
              <v-col cols="12">
                <!-- 走这个落地的用户：多选，默认 = 所选入口入站上的全部现有客户端。
                     每个用户生成一条带 auth_user 的路由规则，在路由列表里逐条可见；
                     一个都不选则退回「整条入站转发」。 -->
                <v-select
                  :label="$t('relay.pickUsers')"
                  :hint="userOptions.length > 0 ? $t('relay.pickUsersHint') : $t('relay.pickUsersEmpty')"
                  persistent-hint
                  :items="userOptions"
                  v-model="form.users"
                  :disabled="userOptions.length === 0"
                  multiple
                  chips
                  clearable
                />
              </v-col>
            </template>

            <!-- ---------------- provision：自动生成入站+用户+出站 ---------------- -->
            <template v-else>
              <v-col cols="12" sm="6">
                <!-- 名称前缀：生成 <前缀><序号>-in / <前缀><序号> / <前缀><序号>-out -->
                <v-text-field
                  :label="$t('relay.prefix')"
                  :hint="$t('relay.prefixHint')"
                  persistent-hint
                  v-model="form.name"
                  :placeholder="'relay'"
                />
              </v-col>
              <v-col cols="12" sm="6">
                <!-- 每个落地节点配几个用户。1 个用户 = 1 条路由规则 -->
                <v-text-field
                  :label="$t('relay.perNode')"
                  :hint="$t('relay.perNodeHint')"
                  persistent-hint
                  type="number"
                  min="1"
                  max="50"
                  v-model.number="form.perNode"
                />
              </v-col>

              <!-- hy2 / anytls 共用：节点地址 / SNI / TLS；混淆只有 hy2 有 -->
              <template v-if="isSocks">
                <v-col cols="12" sm="7">
                  <!-- 写进节点链接的主机名。留空则用当前访问面板的域名/IP -->
                  <v-text-field
                    :label="$t('relay.address')"
                    :hint="$t('relay.addressHint')"
                    persistent-hint
                    v-model="form.address"
                    :placeholder="defaultHost"
                  />
                </v-col>
                <v-col v-if="isHy2" cols="12" sm="5">
                  <v-switch
                    :label="$t('relay.obfs')"
                    :hint="$t('relay.obfsHint')"
                    persistent-hint
                    v-model="form.obfs"
                    color="primary"
                    density="compact"
                    hide-details="auto"
                  />
                </v-col>
                <v-col cols="12" sm="7">
                  <v-text-field
                    :label="$t('relay.sni')"
                    :hint="$t('relay.sniHint')"
                    persistent-hint
                    v-model="form.sni"
                    :placeholder="defaultHost"
                  />
                </v-col>
                <v-col cols="12" sm="5">
                  <v-select
                    :label="$t('relay.tlsCert')"
                    :hint="$t('relay.tlsCertHint')"
                    persistent-hint
                    :items="tlsOptions"
                    v-model="form.tlsId"
                    hide-details="auto"
                  />
                </v-col>
              </template>

              <!-- VLESS+Reality 专用 -->
              <template v-else>
                <v-col cols="12" sm="7">
                  <!-- Reality 伪装域名：握手转发到哪。必须是本机可达的 TLS 站点 -->
                  <v-text-field
                    :label="$t('relay.dest')"
                    :hint="$t('relay.destHint')"
                    persistent-hint
                    v-model="form.dest"
                  />
                </v-col>
                <v-col cols="12" sm="5">
                  <!-- 复用一份已有的 reality 配置，或让向导现场生成一对密钥 -->
                  <v-select
                    :label="$t('relay.tls')"
                    :hint="$t('relay.tlsHint')"
                    persistent-hint
                    :items="tlsOptions"
                    v-model="form.tlsId"
                    hide-details="auto"
                  />
                </v-col>
              </template>
            </template>
          </v-row>

          <!-- 创建结果提示（成功 / 部分失败 / 落地测试未通过） -->
          <v-row v-if="result">
            <v-col cols="12">
              <v-alert :type="result.ok ? 'success' : 'warning'" density="compact" variant="tonal">
                {{ result.text }}
              </v-alert>
            </v-col>
          </v-row>
        </v-container>
      </v-card-text>
      <v-card-actions>
        <v-spacer />
        <v-btn color="primary" variant="outlined" @click="closeModal">{{ $t('actions.close') }}</v-btn>
        <v-btn
          color="primary"
          variant="tonal"
          :loading="loading"
          @click="mode == 'provision' ? createBulk() : createRelay()"
        >
          {{ $t('relay.create') }}
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script lang="ts">
import Data from '@/store/modules/data'
import HttpUtils from '@/plugins/httputil'
import RandomUtil from '@/plugins/randomUtil'
import { i18n } from '@/locales'
import { push } from 'notivue'
import { InTypes, createInbound } from '@/types/inbounds'
import { createClient } from '@/types/clients'

// 自动建站默认的入口协议（旧行为：vless + reality）。
const PROVISION_TYPE = InTypes.VLESS

// 端口随机范围，与「入站管理」页新建入站时用的是同一段。
const PORT_MIN = 10000
const PORT_MAX = 60000

// Reality 伪装站点的默认握手端口。
const DEFAULT_DEST_PORT = 443

// hy2 的 QUIC 只跑 h3，TLS 两侧都显式写上，省得依赖 sing-box 的默认值。
const HY2_ALPN = ['h3']

// tag / 用户名里允许的字符，其余一律换成 '-'。sing-box 的 tag 会被规则、
// 统计、日志到处引用，留着空格或引号只会给自己找麻烦。
function safeName(raw: string): string {
  const cleaned = (raw || '').trim().replace(/[^\w\u4e00-\u9fa5.-]/g, '-').replace(/^-+|-+$/g, '')
  return cleaned.length > 0 ? cleaned : ''
}

// 分享链接末尾的 #备注。socks5 链接没有统一标准，但各家导出的都带 fragment。
function remarkOf(link: string): string {
  const hash = link.indexOf('#')
  if (hash < 0) return ''
  let remark = link.substring(hash + 1)
  try { remark = decodeURIComponent(remark) } catch { /* 不是百分号编码就照原样用 */ }
  return safeName(remark)
}

// 当前访问面板时用的主机名，作为「节点地址 / SNI」的默认值。
function currentHost(): string {
  try {
    return window.location.hostname || ''
  } catch {
    return ''
  }
}

// 节点地址只留主机名：误粘的 http(s):// 前缀和 /path 都去掉。
// 端口不动（入站端口由向导分配，IPv6 的冒号也不能乱切）。
function normalizeHost(raw: string): string {
  let h = (raw || '').trim()
  if (!h) return ''
  h = h.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '')
  h = h.replace(/\/.*$/, '')
  return h.trim()
}

export default {
  props: ['visible'],
  emits: ['close', 'created'],
  data() {
    return {
      loading: false,
      // attach = 接入已有入站；provision = 自动生成入站+用户+出站
      mode: 'attach',
      form: {
        link: '',
        name: '',
        inbounds: <string[]>[],
        users: <string[]>[],
        // --- 以下只有 provision 模式用 ---
        // 入口协议：vless（VLESS+Reality）| hysteria2 / anytls（TLS 入口 + 住宅 socks5）
        protocol: 'vless',
        perNode: 1,
        dest: 'www.apple.com',
        tlsId: 0, // 0 = 让向导现场生成（reality 密钥对 / 自签证书）
        address: '', // 节点链接里的主机名，留空则用当前访问面板的域名/IP
        sni: '',     // 自签证书的域名，同时作为客户端 SNI
        obfs: false, // hy2 的 salamander 混淆
      },
      result: <any>null,
    }
  },
  watch: {
    // 每次打开弹窗都重置表单，避免上一次的输入残留
    visible(v: boolean) {
      if (v) this.reset()
    },
    // 换了入口入站，可选的用户集合就变了：重置成「全选」。
    // 不做增量保留 —— 换入口通常意味着想重新挑一遍用户。
    'form.inbounds'() {
      this.form.users = [...this.userOptions]
    },
    // 粘进来多行，说明想批量建。自动切到自动建站，省得先发现再手动切。
    links(v: string[]) {
      if (v.length > 1 && this.mode == 'attach') this.mode = 'provision'
    },
    // 换协议，之前选的 TLS 就不适用了（reality 配置 vs 证书配置），归零重选
    'form.protocol'() {
      this.form.tlsId = 0
      this.result = null
    },
    mode() {
      this.result = null
    },
  },
  computed: {
    // 链接框按行拆开，去掉空行。attach 模式只用第一行。
    links(): string[] {
      return (this.form.link || '')
        .split('\n')
        .map((l: string) => l.trim())
        .filter((l: string) => l.length > 0)
    },
    isHy2(): boolean {
      return this.form.protocol === 'hysteria2'
    },
    isAnytls(): boolean {
      return this.form.protocol === 'anytls'
    },
    // 「TLS 入口 + socks5 住宅落地」这一族协议：粘贴框都只收 socks5，
    // 地址 / SNI / 证书三个字段共用。目前是 hysteria2（QUIC）与 anytls（TCP）。
    isSocks(): boolean {
      return this.isHy2 || this.isAnytls
    },
    defaultHost(): string {
      return currentHost()
    },
    linkLabel(): string {
      if (this.mode != 'provision') return i18n.global.t('relay.link')
      return this.isSocks ? i18n.global.t('relay.sockList') : i18n.global.t('relay.bulkLinks')
    },
    linkHint(): string {
      if (this.mode != 'provision') return i18n.global.t('relay.linkHint')
      return this.isSocks ? i18n.global.t('relay.sockListHint') : i18n.global.t('relay.bulkLinksHint')
    },
    // socks 模式的逐行解析预览。只做前端判断（socks5 写法固定），
    // 不通过的行在建任何东西之前就标出来。
    bulkPreview(): { index: number, ok: boolean, text: string, detail: string }[] {
      if (!this.isSocks) return []
      return this.links.map((raw: string, i: number) => {
        const parsed = this.parseSocksLine(raw)
        if (!parsed) {
          return { index: i + 1, ok: false, text: raw, detail: i18n.global.t('relay.previewBad') }
        }
        const ob = parsed.ob
        const who = ob.username ? ob.username : i18n.global.t('relay.previewNoAuth')
        const detail = who + (parsed.remark ? ' · ' + parsed.remark : '')
        return { index: i + 1, ok: true, text: ob.server + ':' + ob.server_port, detail }
      })
    },
    // 可作为中转入口的入站 = 携带用户流量的入站（有 users 字段的）。
    // 纯转发的入站（比如落地机上的）不该再被转出去。
    inboundOptions(): string[] {
      return (Data().inbounds || [])
        .filter((i: any) => i.tag && i.users)
        .map((i: any) => i.tag)
    },
    // 所选入口入站上已有的客户端。默认全部选中：
    // 这些用户本来就在这几个入站上，建中转就是想让它们走这个落地。
    userOptions(): string[] {
      const ids = (Data().inbounds || [])
        .filter((i: any) => this.form.inbounds.includes(i.tag))
        .map((i: any) => i.id)
      return (Data().clients || [])
        .filter((c: any) => Array.isArray(c.inbounds) && c.inbounds.some((id: number) => ids.includes(id)))
        .map((c: any) => c.name)
    },
    // TLS 下拉：按协议给不同的候选。
    //   vless          —— 只列开了 reality 的配置
    //   hysteria2/anytls —— 只列带服务端证书的配置（certificate / path / provider 任一）
    tlsOptions(): { title: string, value: number }[] {
      const list = Data().tlsConfigs || []
      if (this.isSocks) {
        const opts = list
          .filter((t: any) => t.server?.enabled && (
            (Array.isArray(t.server?.certificate) && t.server.certificate.length > 0) ||
            t.server?.certificate_path ||
            t.server?.certificate_provider
          ))
          .map((t: any) => ({ title: t.name, value: t.id }))
        return [{ title: i18n.global.t('relay.tlsSelfSigned'), value: 0 }, ...opts]
      }
      const opts = list
        .filter((t: any) => t.server?.reality?.enabled)
        .map((t: any) => ({ title: t.name, value: t.id }))
      return [{ title: i18n.global.t('relay.tlsAuto'), value: 0 }, ...opts]
    },
  },
  methods: {
    reset() {
      // 默认一个入口都不选。路由规则会把选中入站的出口整个改道到落地，
      // 如果默认全选，会把现有所有节点一次性都推到落地 IP 后面
      // （表现为"我原来的节点全变成中转的 IP 了"）。让用户自己挑。
      this.form = {
        link: '', name: '', inbounds: [], users: [],
        protocol: 'vless', perNode: 1, dest: 'www.apple.com', tlsId: 0,
        address: '', sni: '', obfs: false,
      }
      this.mode = 'attach'
      this.result = null
      this.loading = false
    },
    closeModal() {
      this.$emit('close')
    },
    // -----------------------------------------------------------------
    // 解析一行落地节点。socks5 的写法各家不统一，这里收四种：
    //   socks5://[user:pass@]host:port
    //   user:pass@host:port
    //   host:port  /  host:port:user:pass
    // 末尾可带 #备注。host 可以是域名或 IPv4，IPv6 要带方括号。
    // 解析不出返回 null —— attach 模式交给后端 linkConvert 兜底，
    // socks 模式（hy2/anytls）则直接判定这一行不合法。
    // -----------------------------------------------------------------
    splitHostPort(s: string): { host: string, port: number } | null {
      const m = s.match(/^\[([^\]]+)\]:(\d{1,5})$/) || s.match(/^([^:\s]+):(\d{1,5})$/)
      if (!m) return null
      const port = parseInt(m[2], 10)
      if (!Number.isInteger(port) || port < 1 || port > 65535) return null
      return { host: m[1], port }
    },
    parseSocksLine(raw: string): { ob: any, remark: string } | null {
      const src = (raw || '').trim()
      if (!src) return null
      const remark = remarkOf(src)
      const hash = src.indexOf('#')
      let s = (hash >= 0 ? src.substring(0, hash) : src).trim()
      if (!s) return null

      // 1) 带 scheme
      const scheme = s.match(/^socks5?:\/\//i)
      if (scheme) {
        s = s.substring(scheme[0].length).replace(/\/+$/, '')
        let auth = ''
        const at = s.lastIndexOf('@')
        if (at >= 0) { auth = s.substring(0, at); s = s.substring(at + 1) }
        const hp = this.splitHostPort(s)
        if (!hp) return null
        const ob: any = { type: 'socks', server: hp.host, server_port: hp.port, version: '5' }
        if (auth) {
          const c = auth.indexOf(':')
          if (c < 0) {
            ob.username = decodeURIComponent(auth)
          } else {
            ob.username = decodeURIComponent(auth.substring(0, c))
            ob.password = decodeURIComponent(auth.substring(c + 1))
          }
        }
        return { ob, remark }
      }

      // 2) 无 scheme 但带 @：user:pass@host:port
      const at = s.lastIndexOf('@')
      if (at >= 0) {
        const auth = s.substring(0, at)
        const hp = this.splitHostPort(s.substring(at + 1))
        if (!hp) return null
        const ob: any = { type: 'socks', server: hp.host, server_port: hp.port, version: '5' }
        const c = auth.indexOf(':')
        if (c < 0) {
          ob.username = auth
        } else {
          ob.username = auth.substring(0, c)
          ob.password = auth.substring(c + 1)
        }
        return { ob, remark }
      }

      // 3) host:port[:user[:pass]]。密码里可能还有冒号，剩下的整段当密码。
      const parts = s.split(':')
      if (parts.length < 2) return null
      const hp = this.splitHostPort(parts[0] + ':' + parts[1])
      if (!hp) return null
      const ob: any = { type: 'socks', server: hp.host, server_port: hp.port, version: '5' }
      if (parts.length >= 3 && parts[2] !== '') {
        ob.username = parts[2]
        if (parts.length >= 4) ob.password = parts.slice(3).join(':')
      }
      return { ob, remark }
    },
    // attach 模式只要出站对象，备注用不到
    parseSocks(raw: string): any | null {
      const parsed = this.parseSocksLine(raw)
      return parsed ? parsed.ob : null
    },
    // -----------------------------------------------------------------
    // 生成用的两个「取一个不冲突的」小工具。
    // 同一批里也不能重复，所以每次取完就记进集合。
    // -----------------------------------------------------------------
    makeTagPicker(): (base: string) => string {
      const used = new Set<string>([
        ...(Data().outbounds || []).map((o: any) => o.tag),
        ...(Data().endpoints || []).map((e: any) => e.tag),
        ...(Data().inbounds || []).map((i: any) => i.tag),
      ])
      return (base: string) => {
        let tag = base
        let n = 1
        while (used.has(tag)) tag = base + '-' + (n++)
        used.add(tag)
        return tag
      }
    },
    makePortPicker(): () => number {
      const used = new Set<number>(
        (Data().inbounds || [])
          .map((i: any) => i.listen_port)
          .filter((p: any) => Number.isInteger(p))
      )
      return () => {
        for (let t = 0; t < 300; t++) {
          const port = RandomUtil.randomIntRange(PORT_MIN, PORT_MAX)
          if (!used.has(port)) {
            used.add(port)
            return port
          }
        }
        return 0
      }
    },
    // -----------------------------------------------------------------
    // reality 配置。选了已有的就复用；没选（0）就现场生成一对密钥存一份。
    // 返回 tls id，0 表示失败。
    // -----------------------------------------------------------------
    async ensureRealityTls(): Promise<number> {
      if (this.form.tlsId > 0) return this.form.tlsId

      const msg = await HttpUtils.get<string[]>('api/keypairs', { k: 'reality' })
      if (!msg.success || !msg.obj) {
        push.error({ message: i18n.global.t('relay.bulkNoTls') })
        return 0
      }
      let priv = ''
      let pub = ''
      msg.obj.forEach((line: string) => {
        // 后端给的每行形如 "PrivateKey: xxxx" / "PublicKey: xxxx"
        if (line.startsWith('PrivateKey')) priv = line.substring(12).trim()
        if (line.startsWith('PublicKey')) pub = line.substring(11).trim()
      })
      if (priv == '' || pub == '') {
        push.error({ message: i18n.global.t('relay.bulkNoTls') })
        return 0
      }

      const name = safeName(this.form.name) || 'relay'
      const tlsName = name + '-reality-' + RandomUtil.randomLowerAndNum(4)
      const dest = (this.form.dest || '').trim()
      const tls = {
        id: 0,
        name: tlsName,
        server: {
          enabled: true,
          // reality 服务端仍要报一个 SNI，就用伪装域名。
          server_name: dest,
          reality: {
            enabled: true,
            handshake: { server: dest, server_port: DEFAULT_DEST_PORT },
            private_key: priv,
            short_id: RandomUtil.randomShortId(),
          },
        },
        client: {
          reality: { enabled: true, public_key: pub },
          utls: <any>{ enabled: true, fingerprint: 'chrome' },
        },
      }
      if (!await Data().save('tls', 'new', tls)) return 0
      const saved = (Data().tlsConfigs || []).find((t: any) => t.name == tlsName)
      if (!saved?.id) {
        push.error({ message: i18n.global.t('relay.bulkNoTls') })
        return 0
      }
      return saved.id
    },
    // -----------------------------------------------------------------
    // hy2 / anytls 的 TLS：这两种入口都必须跑 TLS，没有「裸协议」这种选项。
    // 选了已有配置就复用；没选就现场签一张自签证书。
    //
    // 自签那份的客户端侧带 insecure: true —— LinkGenerator 会把它写成
    // 链接里的 insecure=1，否则客户端会拿自签证书去校验链，必然失败。
    // 用户填的 SNI 同时进证书 CN/SAN 和服务端 server_name：
    // 前者让「有域名 + 自签」的组合也能对得上，后者决定链接里的 sni 参数。
    //
    // alpn 只给 hy2 写 h3（QUIC 只跑 h3，写死省得依赖 sing-box 默认值）；
    // anytls 跑在普通 TCP/TLS 上，写死 alpn 反而可能跟客户端对不上，留空。
    // -----------------------------------------------------------------
    async ensureCertTls(): Promise<number> {
      if (this.form.tlsId > 0) return this.form.tlsId
      const hy2 = this.isHy2

      const sni = normalizeHost(this.form.sni) || currentHost() || 'www.bing.com'
      const msg = await HttpUtils.get<string[]>('api/keypairs', { k: 'tls', o: sni })
      if (!msg.success || !Array.isArray(msg.obj) || msg.obj.length == 0) {
        push.error({ message: i18n.global.t('relay.bulkNoTls') })
        return 0
      }
      // 后端一次性给出「私钥 PEM + 证书 PEM」，按 BEGIN/END 标记切开。
      const key: string[] = []
      const cert: string[] = []
      let mode = ''
      msg.obj.forEach((line: string) => {
        if (line === '-----BEGIN PRIVATE KEY-----') { mode = 'key'; key.push(line) }
        else if (line === '-----END PRIVATE KEY-----') { key.push(line); mode = '' }
        else if (line === '-----BEGIN CERTIFICATE-----') { mode = 'cert'; cert.push(line) }
        else if (line === '-----END CERTIFICATE-----') { cert.push(line); mode = '' }
        else if (mode === 'key') key.push(line)
        else if (mode === 'cert') cert.push(line)
      })
      if (key.length == 0 || cert.length == 0) {
        push.error({ message: i18n.global.t('relay.bulkNoTls') })
        return 0
      }

      const name = safeName(this.form.name) || 'relay'
      const tlsName = name + '-' + (hy2 ? 'hy2' : 'anytls') + '-' + RandomUtil.randomLowerAndNum(4)
      const tls: any = {
        id: 0,
        name: tlsName,
        server: {
          enabled: true,
          server_name: sni,
          certificate: cert,
          key: key,
        },
        client: {
          // 自签证书只能靠 insecure 过，链接里会带 insecure=1
          insecure: true,
        },
      }
      if (hy2) {
        tls.server.alpn = HY2_ALPN
        tls.client.alpn = HY2_ALPN
      }
      if (!await Data().save('tls', 'new', tls)) return 0
      const saved = (Data().tlsConfigs || []).find((t: any) => t.name == tlsName)
      if (!saved?.id) {
        push.error({ message: i18n.global.t('relay.bulkNoTls') })
        return 0
      }
      return saved.id
    },
    // =================================================================
    // A. 接入已有入站
    // =================================================================
    async createRelay() {
      const link = (this.form.link || '').trim()
      if (!link) {
        push.error({ message: i18n.global.t('error.invalidData') + ': ' + i18n.global.t('relay.link') })
        return
      }
      if (this.form.inbounds.length === 0) {
        push.error({ message: i18n.global.t('error.invalidData') + ': ' + i18n.global.t('relay.entry') })
        return
      }
      this.loading = true
      this.result = null
      try {
        // 1) 构造落地出站。SOCKS5 在前端解析；其它协议走后端分享链接转换。
        let outbound: any = this.parseSocks(link)
        if (!outbound) {
          const conv = await HttpUtils.post<{ type?: string; tag?: string }>('api/linkConvert', { link })
          if (!conv.success || !conv.obj || !conv.obj.type) {
            push.error({ message: i18n.global.t('relay.convertFail') })
            return
          }
          outbound = conv.obj
        }

        // 2) 选一个不与现有出站/端点/入站冲突的 tag。
        //    优先用用户填的名称，其次用转换结果自带的 tag，最后随机生成。
        const pickTag = this.makeTagPicker()
        const base = (this.form.name || '').trim() || outbound.tag || ('relay-' + RandomUtil.randomLowerAndNum(6))
        outbound.tag = pickTag(base)
        // id 是后端数据库字段，新建时不能带过去
        delete outbound.id

        // 3) 保存落地出站。
        if (!await Data().save('outbounds', 'new', outbound)) return

        // 4) 追加路由规则。按用户分流：每个选中的用户一条
        //    {inbound, auth_user:[用户名], action:'route', outbound}。
        //    inbound 写本中转的全部入口入站：用户只能在自己绑定的入站上认证，
        //    多写的永远匹配不上，但以后把用户挂到另一个入口入站时规则不用跟着改。
        //    一个用户都没选则退回旧形态（整条入站转发，不限用户）——
        //    不然建出来的中转一条规则都没有，页面也不会显示它。
        const config = JSON.parse(JSON.stringify(Data().config || {}))
        if (!config.route) config.route = {}
        if (!Array.isArray(config.route.rules)) config.route.rules = []
        const entryTags = [...this.form.inbounds]
        const legacy = this.form.users.length === 0
        if (legacy) {
          config.route.rules.push({ inbound: entryTags, action: 'route', outbound: outbound.tag })
        } else {
          this.form.users.forEach((name: string) => {
            config.route.rules.push({ inbound: [...entryTags], auth_user: [name], action: 'route', outbound: outbound.tag })
          })
        }

        // 5) 保存完整 config（触发核心重启，出站与路由同时生效）。
        if (!await Data().save('config', 'set', config)) return
        if (legacy) push.info({ message: i18n.global.t('relay.legacyFallback') })

        // 6) 探测落地连通性，把结果展示在弹窗里。
        const test = await HttpUtils.get<{ OK: boolean; Delay?: number; Error?: string }>('api/checkOutbound', { tag: outbound.tag })
        if (test.success && test.obj?.OK) {
          this.result = { ok: true, text: i18n.global.t('relay.testOk') + ': ' + test.obj.Delay + i18n.global.t('date.ms') }
          push.success({ title: i18n.global.t('success'), message: i18n.global.t('relay.success') })
        } else {
          this.result = { ok: false, text: i18n.global.t('relay.testFail') + ': ' + (test.obj?.Error || '') }
          push.success({ title: i18n.global.t('success'), message: i18n.global.t('relay.successButTest') })
        }
        this.form.link = ''
      } catch (e: any) {
        push.error({ message: i18n.global.t('error.invalidData') + ': ' + (e?.toString() ?? '') })
      } finally {
        this.loading = false
      }
    },
    // =================================================================
    // B. 自动建站：N 行链接 -> N 组（入站 + 用户 + 出站）+ N×用户数 条规则
    // =================================================================
    async createBulk() {
      const links = this.links
      if (links.length === 0) {
        push.error({ message: i18n.global.t('error.invalidData') + ': ' + this.linkLabel })
        return
      }
      const hy2 = this.isHy2
      const socks = this.isSocks // hy2 / anytls：只收 socks5，地址/SNI/证书共用
      const perNode = Math.min(Math.max(Math.floor(this.form.perNode) || 1, 1), 50)
      this.loading = true
      this.result = null
      try {
        // 1) 先把全部链接解析成出站对象。放在建任何东西之前：
        //    建到第 8 条才发现第 9 行拼错了，留下的就是一堆没有规则的半成品。
        //    socks 模式这里只认 socks5（住宅代理导出的就是这几种写法），
        //    不再走后端 linkConvert —— 免得把一条 vless 链接悄悄做成 socks 落地。
        const nodes: { ob: any, remark: string }[] = []
        for (let i = 0; i < links.length; i++) {
          if (socks) {
            const parsed = this.parseSocksLine(links[i])
            if (!parsed) {
              push.error({ message: i18n.global.t('relay.parseSocksLine', { n: i + 1 }) })
              return
            }
            nodes.push(parsed)
            continue
          }
          let ob: any = this.parseSocks(links[i])
          if (!ob) {
            const conv = await HttpUtils.post<{ type?: string; tag?: string }>('api/linkConvert', { link: links[i] })
            if (!conv.success || !conv.obj || !conv.obj.type) {
              push.error({ message: i18n.global.t('relay.parseFailLine', { n: i + 1 }) })
              return
            }
            ob = conv.obj
          }
          nodes.push({ ob, remark: remarkOf(links[i]) })
        }

        // 2) TLS：vless 要 reality 密钥对，hy2/anytls 要服务端证书。
        const tlsId = socks ? await this.ensureCertTls() : await this.ensureRealityTls()
        if (!tlsId) return

        const pickTag = this.makeTagPicker()
        const pickPort = this.makePortPicker()
        const prefix = safeName(this.form.name) || 'relay'
        // 链接里用的主机名：填了就写进入站的 addrs，留空则后端用请求的 Host
        const addr = socks ? normalizeHost(this.form.address) : ''
        const rules: any[] = []
        const failed: string[] = []
        const createdTags: string[] = []
        const takenNames = new Set<string>((Data().clients || []).map((c: any) => c.name))
        let done = 0

        // 3) 逐条建。顺序是 入站 -> 用户 -> 出站：
        //    用户要拿入站的 id 才能绑上去，而后端在保存客户端时会顺手把用户
        //    凭据写进入站的 users 字段（service/config.go 的 clients 分支）。
        for (let i = 0; i < nodes.length; i++) {
          const node = nodes[i]
          // 链接自带备注就用备注，否则 <前缀><序号>，这样路由列表里一眼能认出是谁
          let base = node.remark || (prefix + (i + 1))
          let seq = 1
          while (takenNames.has(base)) base = (node.remark || prefix + (i + 1)) + '-' + (seq++)

          const inTag = pickTag(base + '-in')
          const outTag = pickTag(base + '-out')
          const port = pickPort()
          if (port == 0) {
            failed.push(base + ' (' + i18n.global.t('relay.noPort') + ')')
            continue
          }

          // 3a) 入口入站。addrs / out_json 是「入站管理」页新建时也会带的字段，
          //     缺了它们客户端链接就拼不出来。anytls 工厂自带 padding_scheme。
          const inbound: any = hy2
            ? createInbound(InTypes.Hysteria2, {
                id: 0, tag: inTag, listen: '::', listen_port: port, tls_id: tlsId,
              })
            : socks
              ? createInbound(InTypes.AnyTls, {
                  id: 0, tag: inTag, listen: '::', listen_port: port, tls_id: tlsId,
                })
              : createInbound(PROVISION_TYPE, {
                  id: 0, tag: inTag, listen: '::', listen_port: port, tls_id: tlsId,
                })
          if (hy2 && this.form.obfs) {
            // 每个入站一把混淆密码，链接里会带 obfs=salamander&obfs-password=...
            inbound.obfs = { type: 'salamander', password: RandomUtil.randomSeq(16) }
          }
          inbound.addrs = addr ? [{ server: addr, server_port: port, remark: '' }] : []
          inbound.out_json = {}
          if (!await Data().save('inbounds', 'new', inbound)) {
            failed.push(base)
            continue
          }
          const savedInbound = (Data().inbounds || []).find((x: any) => x.tag == inTag)
          if (!savedInbound?.id) {
            failed.push(base)
            continue
          }

          // 3b) 用户。每节点 perNode 个，各占一条路由规则（与 attach 模式一致）。
          //     hy2 的凭据是 config.hysteria2.password，anytls 是 config.anytls.password
          //     （sing-anytls 按密码认证，不用 uuid）；后端按这些字段生成入站的
          //     users 列表。name 也要一起写进去（sing-box 用它做会话/统计）。
          //     同一个节点的用户攒成一个数组走 addbulk：每存一次都会重启核心，
          //     批量导几十个节点时这一下能省掉大半的重启。
          const names: string[] = []
          const clients: any[] = []
          for (let u = 0; u < perNode; u++) {
            const userName = perNode == 1 ? base : base + '-' + (u + 1)
            takenNames.add(userName)
            const client: any = createClient({ name: userName, inbounds: [savedInbound.id] })
            if (hy2 || socks) {
              const cfg = client.config || {}
              if (hy2) cfg.hysteria2 = { name: userName, password: RandomUtil.randomSeq(16) }
              else cfg.anytls = { name: userName, password: RandomUtil.randomSeq(16) }
              client.config = cfg
            }
            clients.push(client)
            names.push(userName)
          }
          if (!await Data().save('clients', 'addbulk', clients)) {
            failed.push(base)
            continue
          }

          // 3c) 落地出站（从链接解析出来的那个 socks 节点）。
          const outbound: any = { ...node.ob, tag: outTag }
          delete outbound.id
          if (!await Data().save('outbounds', 'new', outbound)) {
            failed.push(base)
            continue
          }

          // 3d) 路由规则：入站 + 用户 + 出站三项在这里合到一起。
          names.forEach((name: string) => {
            rules.push({ inbound: [inTag], auth_user: [name], action: 'route', outbound: outTag })
          })
          createdTags.push(inTag)
          done++
        }

        if (done == 0) {
          push.error({ message: i18n.global.t('relay.bulkFail', { list: failed.join(', ') }) })
          return
        }

        // 4) 规则攒到最后一次性写。config 是唯一会重启核心的 object，
        //    N 个节点也只重启一次。
        const config = JSON.parse(JSON.stringify(Data().config || {}))
        if (!config.route) config.route = {}
        if (!Array.isArray(config.route.rules)) config.route.rules = []
        config.route.rules.push(...rules)
        if (!await Data().save('config', 'set', config)) {
          push.error({ message: i18n.global.t('relay.bulkRulesFail', { n: done }) })
          return
        }

        const created = i18n.global.t(
          hy2 ? 'relay.bulkDoneHy2' : (socks ? 'relay.bulkDoneAnytls' : 'relay.bulkDone'),
          { n: done, rules: rules.length })
        this.result = failed.length == 0
          ? { ok: true, text: created }
          : { ok: false, text: created + ' / ' + i18n.global.t('relay.bulkFail', { list: failed.join(', ') }) }
        push.success({ title: i18n.global.t('success'), message: created })
        this.form.link = ''

        // 5) 把新建的入口入站交给中转页：它会打开「节点链接」弹窗，
        //    把每个用户的 anytls:// 或 hysteria2:// 链接直接摊出来（复制 / 二维码 / Base64）。
        if (createdTags.length > 0) {
          this.$emit('created', { tags: createdTags, title: prefix })
        }
      } catch (e: any) {
        push.error({ message: i18n.global.t('error.invalidData') + ': ' + (e?.toString() ?? '') })
      } finally {
        this.loading = false
      }
    },
  },
}
</script>
