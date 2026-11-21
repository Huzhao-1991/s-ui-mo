<template>
  <!-- ======================================================================
    一键搭建节点（Hysteria2 / Trojan / AnyTLS）
    --------------------------------------------------------------------
    面板左侧菜单里的独立入口，做的事很单一：选协议、填几个字段，直接在本机
    生成 N 个入站 + 每个入站上的用户，然后把节点链接摊出来。

    与「中转管理」的区别：那边是「入口 + 住宅 socks5 落地」，要出站和路由规则；
    这边不碰出站、不写路由，建出来的就是本机直出的普通节点 —— 适合
    「手上有一台 VPS，想赶紧开几个节点给客户端用」的场景。

    三种协议的共同点：都必须跑 TLS（hy2 是 QUIC 固有要求；trojan / anytls
    的客户端也按 TLS 语义连接，裸跑的链接客户端认不了），所以 TLS 字段共用，
    自签那份客户端侧带 insecure，链接里会自动出现 insecure=1。

    差异点：
      - hysteria2 跑 QUIC/UDP，TLS 两侧写死 alpn=h3；可选 salamander 混淆
      - trojan / anytls 跑 TCP/TLS，alpn 留空不写死；没有混淆的概念
      - anytls 入站自带 padding_scheme（sing-anytls 的默认流量整形）

    后端不需要任何新接口，全部复用：
      - api/keypairs?k=tls&o=<SNI>   现场签自签证书（要证书就用，不要就复用已有 TLS）
      - api/save object=tls          保存自签证书配置
      - api/save object=inbounds     建入站
      - api/save object=clients      addbulk 一次建完一个入站上的全部用户
      - api/clients?id=…             取带 links 的完整客户端行（链接弹窗用）
      - util/genLink.go              链接生成（hysteria2:// / trojan:// / anytls://）

    端口：默认从 10000-60000 随机挑没被占用的；也可以指定起始端口顺序分配。
    ====================================================================== -->
  <RelayLinks
    :visible="links.visible"
    :inbound-tags="links.tags"
    :title="links.title"
    :heading="$t('quick.linksTitle', { proto: protoName })"
    :desc="$t('quick.linksDesc', { proto: protoName })"
    @close="links.visible = false"
  />

  <v-row>
    <!-- 左：创建表单 -->
    <v-col cols="12" md="5">
      <v-card rounded="xl" elevation="3" :title="$t('quick.formTitle')" :subtitle="$t('quick.formSubtitle')">
        <v-card-text>
          <v-row dense>
            <v-col cols="12">
              <v-btn-toggle v-model="form.protocol" mandatory color="primary" density="compact">
                <v-btn value="hysteria2" size="small">{{ $t('quick.protoHy2') }}</v-btn>
                <v-btn value="trojan" size="small">{{ $t('quick.protoTrojan') }}</v-btn>
                <v-btn value="anytls" size="small">{{ $t('quick.protoAnytls') }}</v-btn>
              </v-btn-toggle>
              <p style="font-size: 0.78rem; opacity: 0.75; margin-top: 6px;">
                {{ $t('quick.protoHint_' + form.protocol) }}
              </p>
            </v-col>
            <v-col cols="6">
              <v-text-field
                v-model.number="form.count"
                type="number"
                min="1"
                max="50"
                :label="$t('quick.count')"
                :hint="$t('quick.countHint')"
                persistent-hint
              />
            </v-col>
            <v-col cols="6">
              <v-text-field
                v-model.number="form.perNode"
                type="number"
                min="1"
                max="50"
                :label="$t('quick.perNode')"
                :hint="$t('quick.perNodeHint')"
                persistent-hint
              />
            </v-col>
            <v-col cols="12">
              <v-text-field
                v-model="form.prefix"
                :label="$t('quick.prefix')"
                :hint="$t('quick.prefixHint')"
                persistent-hint
                :placeholder="form.protocol"
              />
            </v-col>
            <v-col cols="12">
              <v-switch
                v-model="form.autoPort"
                :label="$t('quick.autoPort')"
                :hint="$t('quick.autoPortHint')"
                persistent-hint
                color="primary"
                density="compact"
                hide-details="auto"
              />
            </v-col>
            <v-col v-if="!form.autoPort" cols="12">
              <v-text-field
                v-model.number="form.startPort"
                type="number"
                min="1"
                max="65535"
                :label="$t('quick.startPort')"
                :hint="$t('quick.startPortHint')"
                persistent-hint
              />
            </v-col>
            <v-col cols="12">
              <v-text-field
                v-model="form.address"
                :label="$t('quick.address')"
                :hint="$t('quick.addressHint')"
                persistent-hint
                :placeholder="defaultHost"
              />
            </v-col>
            <v-col cols="12">
              <v-text-field
                v-model="form.sni"
                :label="$t('quick.sni')"
                :hint="$t('quick.sniHint')"
                persistent-hint
                :placeholder="defaultHost"
              />
            </v-col>
            <v-col cols="12">
              <v-select
                v-model="form.tlsId"
                :items="tlsOptions"
                :label="$t('quick.tls')"
                :hint="$t('quick.tlsHint')"
                persistent-hint
              />
            </v-col>
            <v-col v-if="form.protocol === 'hysteria2'" cols="12">
              <v-switch
                v-model="form.obfs"
                :label="$t('quick.obfs')"
                :hint="$t('quick.obfsHint')"
                persistent-hint
                color="primary"
                density="compact"
                hide-details="auto"
              />
            </v-col>
          </v-row>

          <v-alert v-if="result" :type="result.ok ? 'success' : 'warning'" density="compact" variant="tonal" class="mt-4">
            {{ result.text }}
          </v-alert>
        </v-card-text>
        <v-card-actions>
          <v-spacer />
          <v-btn
            color="primary"
            variant="tonal"
            prepend-icon="mdi-flash"
            :loading="loading"
            @click="create"
          >
            {{ $t('quick.create') }}
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-col>

    <!-- 右：当前协议已有的节点，随时能再看链接 -->
    <v-col cols="12" md="7">
      <v-card rounded="xl" elevation="3" :title="$t('quick.existingTitle', { proto: protoName })" :subtitle="$t('quick.existingSubtitle', { proto: protoName })">
        <v-card-text>
          <div v-if="rows.length === 0" style="text-align: center; opacity: 0.6; padding: 28px;">
            {{ $t('quick.empty', { proto: protoName }) }}
          </div>
          <v-table v-else density="compact">
            <thead>
              <tr>
                <th>{{ $t('quick.colTag') }}</th>
                <th>{{ $t('quick.colPort') }}</th>
                <th>{{ $t('quick.colUsers') }}</th>
                <th>{{ $t('quick.colTls') }}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in rows" :key="r.id">
                <td>{{ r.tag }}</td>
                <td>{{ r.port }}</td>
                <td>{{ r.users }}</td>
                <td>{{ r.tls }}</td>
                <td style="text-align: end;">
                  <v-btn
                    size="small"
                    variant="text"
                    color="primary"
                    prepend-icon="mdi-link-variant"
                    @click="openLinks([r.tag], r.tag)"
                  >
                    {{ $t('quick.links') }}
                  </v-btn>
                </td>
              </tr>
            </tbody>
          </v-table>
        </v-card-text>
      </v-card>
    </v-col>
  </v-row>
</template>

<script lang="ts">
import Data from '@/store/modules/data'
import HttpUtils from '@/plugins/httputil'
import RandomUtil from '@/plugins/randomUtil'
import { i18n } from '@/locales'
import { push } from 'notivue'
import { InTypes, createInbound } from '@/types/inbounds'
import { createClient } from '@/types/clients'
import RelayLinks from '@/layouts/modals/RelayLinks.vue'
import { currentHost, normalizeHost, safeName } from '@/plugins/naming'

// 端口随机范围，与「入站管理」页新建入站、「中转向导」用的是同一段。
const PORT_MIN = 10000
const PORT_MAX = 60000

// hy2 的 QUIC 只跑 h3，TLS 两侧都显式写上，省得依赖 sing-box 的默认值。
const HY2_ALPN = ['h3']

// 三种协议的差异全部收在这张表里：
//   type   —— 入站工厂用的 InTypes 枚举
//   cred   —— 用户凭据写在 config 的哪个键下（sing-box 都按 password 认证，
//             name 同时是会话/统计标识，缺了流量统计会是空白）
//   suffix —— 自签 TLS 配置名的协议后缀
//   alpn   —— hy2 写死 h3；trojan / anytls 留空不写死
type ProtoKey = 'hysteria2' | 'trojan' | 'anytls'
const PROTOCOLS: Record<ProtoKey, {
  type: string, cred: string, suffix: string, alpn?: string[]
}> = {
  hysteria2: { type: InTypes.Hysteria2, cred: 'hysteria2', suffix: 'hy2', alpn: HY2_ALPN },
  trojan:    { type: InTypes.Trojan,    cred: 'trojan',    suffix: 'trojan' },
  anytls:    { type: InTypes.AnyTls,    cred: 'anytls',    suffix: 'anytls' },
}

export default {
  components: { RelayLinks },
  data() {
    return {
      loading: false,
      result: <any>null,
      form: {
        protocol: <ProtoKey>'hysteria2',
        count: 1,          // 建几个节点
        perNode: 1,        // 每个节点上几个用户
        prefix: 'hy2',     // tag / 用户名的前缀
        autoPort: true,    // true = 随机挑空闲端口；false = 从 startPort 顺序分配
        startPort: 20000,
        address: '',       // 写进入站 addrs，链接里就用它；留空回退到面板域名
        sni: '',           // 自签证书的域名，同时作为客户端 SNI
        tlsId: 0,          // 0 = 现场自签；>0 = 复用已有证书配置
        obfs: false,       // salamander 混淆（仅 hysteria2）
      },
      links: {
        visible: false,
        tags: <string[]>[],
        title: '',
      },
    }
  },
  watch: {
    // 换协议时把前缀重置成对应默认值 —— 上次填的 hy2 前缀拖到 trojan 上只会困惑。
    'form.protocol'(v: ProtoKey) {
      this.form.prefix = v
    },
  },
  computed: {
    proto(): (typeof PROTOCOLS)[ProtoKey] {
      return PROTOCOLS[this.form.protocol] || PROTOCOLS.hysteria2
    },
    protoName(): string {
      return i18n.global.t('quick.proto' + this.form.protocol.charAt(0).toUpperCase() + this.form.protocol.slice(1))
        || this.form.protocol
    },
    defaultHost(): string {
      return currentHost()
    },
    // TLS 下拉：只列带服务端证书的配置（certificate / path / provider 任一），
    // 第一条永远是「现场自签」。reality 配置在这条链路上用不了，不列。
    tlsOptions(): { title: string, value: number }[] {
      const opts = (Data().tlsConfigs || [])
        .filter((t: any) => t.server?.enabled && (
          (Array.isArray(t.server?.certificate) && t.server.certificate.length > 0) ||
          t.server?.certificate_path ||
          t.server?.certificate_provider
        ))
        .map((t: any) => ({ title: t.name, value: t.id }))
      return [{ title: i18n.global.t('quick.tlsSelfSigned'), value: 0 }, ...opts]
    },
    // 当前协议的已有入站列表：按端口排序，用户数从客户端表里数出来。
    rows(): { id: number, tag: string, port: number, users: number, tls: string }[] {
      const clients = Data().clients || []
      const type = this.proto.type
      return (Data().inbounds || [])
        .filter((i: any) => i.type === type)
        .map((i: any) => ({
          id: i.id,
          tag: i.tag,
          port: i.listen_port,
          users: clients.filter((c: any) => Array.isArray(c.inbounds) && c.inbounds.includes(i.id)).length,
          tls: i.tls_id > 0 ? i18n.global.t('enable') : i18n.global.t('disable'),
        }))
        .sort((a: any, b: any) => (a.port || 0) - (b.port || 0))
    },
  },
  methods: {
    openLinks(tags: string[], title: string) {
      this.links.tags = tags
      this.links.title = title
      this.links.visible = true
    },
    // -----------------------------------------------------------------
    // 端口分配。同一批里也不能重复，所以每个取完就记进集合。
    // 随机模式最多试 300×N 次；手动模式从起始端口往上找空位。
    // 返回的数组长度不足 count 就说明没有足够端口，调用方直接中止。
    // -----------------------------------------------------------------
    allocPorts(count: number): number[] {
      const used = new Set<number>(
        (Data().inbounds || [])
          .map((i: any) => i.listen_port)
          .filter((p: any) => Number.isInteger(p))
      )
      const ports: number[] = []
      if (this.form.autoPort) {
        for (let attempt = 0; attempt < 300 * count && ports.length < count; attempt++) {
          const port = RandomUtil.randomIntRange(PORT_MIN, PORT_MAX)
          if (used.has(port)) continue
          used.add(port)
          ports.push(port)
        }
        return ports
      }
      let port = Math.floor(this.form.startPort) || PORT_MIN
      while (ports.length < count && port <= 65535) {
        if (!used.has(port)) {
          used.add(port)
          ports.push(port)
        }
        port++
      }
      return ports
    },
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
    // -----------------------------------------------------------------
    // TLS：选了已有配置就复用；否则现场签一张自签证书。
    // 一批节点共用同一份证书 —— 域名一样，签 N 份只会在 TLS 列表里堆垃圾。
    // 自签的客户端侧带 insecure: true，后端 LinkGenerator 会写成 insecure=1。
    // alpn 只给 hysteria2 写 h3（QUIC 只跑 h3）；trojan / anytls 留空，
    // 不写死免得跟客户端对不上。
    // -----------------------------------------------------------------
    async ensureTls(prefix: string): Promise<number> {
      if (this.form.tlsId > 0) return this.form.tlsId

      const sni = normalizeHost(this.form.sni) || currentHost() || 'www.bing.com'
      const msg = await HttpUtils.get<string[]>('api/keypairs', { k: 'tls', o: sni })
      if (!msg.success || !Array.isArray(msg.obj) || msg.obj.length == 0) {
        push.error({ message: i18n.global.t('quick.noTls') })
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
        push.error({ message: i18n.global.t('quick.noTls') })
        return 0
      }

      const tlsName = prefix + '-' + this.proto.suffix + '-' + RandomUtil.randomLowerAndNum(4)
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
      if (this.proto.alpn) {
        tls.server.alpn = this.proto.alpn
        tls.client.alpn = this.proto.alpn
      }
      if (!await Data().save('tls', 'new', tls)) return 0
      const saved = (Data().tlsConfigs || []).find((t: any) => t.name == tlsName)
      if (!saved?.id) {
        push.error({ message: i18n.global.t('quick.noTls') })
        return 0
      }
      return saved.id
    },
    // -----------------------------------------------------------------
    // 一键创建：端口 → TLS → 逐个入站 → 每个入站的用户（addbulk）。
    // 用户凭据写在 config.<cred> = {name, password}：三种协议都按密码认证，
    // name 同时是 sing-box 侧的会话/统计标识，缺了流量统计会是空白。
    // -----------------------------------------------------------------
    async create() {
      const count = Math.min(Math.max(Math.floor(this.form.count) || 1, 1), 50)
      const perNode = Math.min(Math.max(Math.floor(this.form.perNode) || 1, 1), 50)
      const protoKey: ProtoKey = this.form.protocol
      const proto = this.proto
      const prefix = safeName(this.form.prefix) || protoKey

      const ports = this.allocPorts(count)
      if (ports.length < count) {
        push.error({ message: i18n.global.t('quick.noPort') })
        return
      }

      this.loading = true
      this.result = null
      try {
        const tlsId = await this.ensureTls(prefix)
        if (!tlsId) return

        const pickTag = this.makeTagPicker()
        const addr = normalizeHost(this.form.address)
        const takenNames = new Set<string>((Data().clients || []).map((c: any) => c.name))
        const tags: string[] = []
        const failed: string[] = []
        let users = 0

        for (let i = 0; i < count; i++) {
          const base = count == 1 ? prefix : prefix + '-' + (i + 1)
          const tag = pickTag(base)
          const port = ports[i]

          // 1) 入站。addrs / out_json 是「入站管理」页新建时也会带的字段，
          //    缺了它们客户端链接就拼不出来。anytls 工厂自带 padding_scheme。
          const inbound: any = createInbound(proto.type, {
            id: 0, tag, listen: '::', listen_port: port, tls_id: tlsId,
          })
          if (protoKey === 'hysteria2' && this.form.obfs) {
            // 每个入站一把混淆密码，链接里会带 obfs=salamander&obfs-password=...
            inbound.obfs = { type: 'salamander', password: RandomUtil.randomSeq(16) }
          }
          inbound.addrs = addr ? [{ server: addr, server_port: port, remark: '' }] : []
          inbound.out_json = {}
          if (!await Data().save('inbounds', 'new', inbound)) {
            failed.push(base)
            continue
          }
          const savedInbound = (Data().inbounds || []).find((x: any) => x.tag == tag)
          if (!savedInbound?.id) {
            failed.push(base)
            continue
          }

          // 2) 用户。名字重复就加序号，不然 addbulk 会因重名整批失败。
          const clients: any[] = []
          for (let u = 0; u < perNode; u++) {
            let userName = perNode == 1 ? base : base + '-' + (u + 1)
            let seq = 1
            while (takenNames.has(userName)) userName = (perNode == 1 ? base : base + '-' + (u + 1)) + '-' + (seq++)
            takenNames.add(userName)

            const client: any = createClient({ name: userName, inbounds: [savedInbound.id] })
            const cfg = client.config || {}
            cfg[proto.cred] = { name: userName, password: RandomUtil.randomSeq(16) }
            client.config = cfg
            clients.push(client)
          }
          // addbulk：一个节点的用户整批一次提交，别一个个存。
          if (!await Data().save('clients', 'addbulk', clients)) {
            failed.push(base)
            continue
          }

          users += clients.length
          tags.push(tag)
        }

        if (tags.length === 0) {
          this.result = { ok: false, text: i18n.global.t('quick.fail', { list: failed.join(', ') }) }
          push.error({ message: this.result.text })
          return
        }

        const done = i18n.global.t('quick.created', { n: tags.length, users, proto: this.protoName })
        this.result = failed.length == 0
          ? { ok: true, text: done }
          : { ok: false, text: done + ' / ' + i18n.global.t('quick.fail', { list: failed.join(', ') }) }
        push.success({ title: i18n.global.t('success'), message: done })

        // 3) 建完直接把链接摊出来（复制 / 二维码 / Base64 整包）。
        this.openLinks(tags, prefix)
      } catch (e: any) {
        push.error({ message: i18n.global.t('error.invalidData') + ': ' + (e?.toString() ?? '') })
      } finally {
        this.loading = false
      }
    },
  },
}
</script>
