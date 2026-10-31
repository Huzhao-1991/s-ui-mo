<template>
  <!-- ======================================================================
    一键搭建 Hysteria2 节点（Hy2）
    --------------------------------------------------------------------
    面板左侧菜单里的独立入口，做的事很单一：填几个字段，直接在本机生成
    N 个 Hysteria2 入站 + 每个入站上的用户，然后把 hysteria2:// 链接摊出来。

    与「中转管理」的区别：那边是「入口 + 住宅 socks5 落地」，要出站和路由规则；
    这边不碰出站、不写路由，建出来的就是本机直出的普通节点 —— 适合
    「手上有一台 VPS，想赶紧开几个 hy2 节点给客户端用」的场景。

    后端不需要任何新接口，全部复用：
      - api/keypairs?k=tls&o=<SNI>   现场签自签证书（要证书就用，不要就复用已有 TLS）
      - api/save object=tls          保存自签证书配置
      - api/save object=inbounds     建入站
      - api/save object=clients      addbulk 一次建完一个入站上的全部用户
      - api/clients?id=…             取带 links 的完整客户端行（链接弹窗用）

    端口：默认从 10000-60000 随机挑没被占用的；也可以指定起始端口顺序分配。
    TLS：hy2 必须跑 TLS。自签那份客户端侧带 insecure，链接里会自动出现
    insecure=1；服务端与客户端两侧都写死 alpn=h3（QUIC 只跑 h3）。
    ====================================================================== -->
  <RelayLinks
    :visible="links.visible"
    :inbound-tags="links.tags"
    :title="links.title"
    :heading="$t('hy2.linksTitle')"
    :desc="$t('hy2.linksDesc')"
    @close="links.visible = false"
  />

  <v-row>
    <!-- 左：创建表单 -->
    <v-col cols="12" md="5">
      <v-card rounded="xl" elevation="3" :title="$t('hy2.formTitle')" :subtitle="$t('hy2.formSubtitle')">
        <v-card-text>
          <v-row dense>
            <v-col cols="6">
              <v-text-field
                v-model.number="form.count"
                type="number"
                min="1"
                max="50"
                :label="$t('hy2.count')"
                :hint="$t('hy2.countHint')"
                persistent-hint
              />
            </v-col>
            <v-col cols="6">
              <v-text-field
                v-model.number="form.perNode"
                type="number"
                min="1"
                max="50"
                :label="$t('hy2.perNode')"
                :hint="$t('hy2.perNodeHint')"
                persistent-hint
              />
            </v-col>
            <v-col cols="12">
              <v-text-field
                v-model="form.prefix"
                :label="$t('hy2.prefix')"
                :hint="$t('hy2.prefixHint')"
                persistent-hint
                placeholder="hy2"
              />
            </v-col>
            <v-col cols="12">
              <v-switch
                v-model="form.autoPort"
                :label="$t('hy2.autoPort')"
                :hint="$t('hy2.autoPortHint')"
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
                :label="$t('hy2.startPort')"
                :hint="$t('hy2.startPortHint')"
                persistent-hint
              />
            </v-col>
            <v-col cols="12">
              <v-text-field
                v-model="form.address"
                :label="$t('hy2.address')"
                :hint="$t('hy2.addressHint')"
                persistent-hint
                :placeholder="defaultHost"
              />
            </v-col>
            <v-col cols="12">
              <v-text-field
                v-model="form.sni"
                :label="$t('hy2.sni')"
                :hint="$t('hy2.sniHint')"
                persistent-hint
                :placeholder="defaultHost"
              />
            </v-col>
            <v-col cols="12">
              <v-select
                v-model="form.tlsId"
                :items="tlsOptions"
                :label="$t('hy2.tls')"
                :hint="$t('hy2.tlsHint')"
                persistent-hint
              />
            </v-col>
            <v-col cols="12">
              <v-switch
                v-model="form.obfs"
                :label="$t('hy2.obfs')"
                :hint="$t('hy2.obfsHint')"
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
            {{ $t('hy2.create') }}
          </v-btn>
        </v-card-actions>
      </v-card>
    </v-col>

    <!-- 右：已有的 hy2 节点，随时能再看链接 -->
    <v-col cols="12" md="7">
      <v-card rounded="xl" elevation="3" :title="$t('hy2.existingTitle')" :subtitle="$t('hy2.existingSubtitle')">
        <v-card-text>
          <div v-if="rows.length === 0" style="text-align: center; opacity: 0.6; padding: 28px;">
            {{ $t('hy2.empty') }}
          </div>
          <v-table v-else density="compact">
            <thead>
              <tr>
                <th>{{ $t('hy2.colTag') }}</th>
                <th>{{ $t('hy2.colPort') }}</th>
                <th>{{ $t('hy2.colUsers') }}</th>
                <th>{{ $t('hy2.colTls') }}</th>
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
                    {{ $t('hy2.links') }}
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

export default {
  components: { RelayLinks },
  data() {
    return {
      loading: false,
      result: <any>null,
      form: {
        count: 1,          // 建几个节点
        perNode: 1,        // 每个节点上几个用户
        prefix: 'hy2',     // tag / 用户名的前缀
        autoPort: true,    // true = 随机挑空闲端口；false = 从 startPort 顺序分配
        startPort: 20000,
        address: '',       // 写进入站 addrs，链接里就用它；留空回退到面板域名
        sni: '',           // 自签证书的域名，同时作为客户端 SNI
        tlsId: 0,          // 0 = 现场自签；>0 = 复用已有证书配置
        obfs: false,       // salamander 混淆
      },
      links: {
        visible: false,
        tags: <string[]>[],
        title: '',
      },
    }
  },
  computed: {
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
      return [{ title: i18n.global.t('hy2.tlsSelfSigned'), value: 0 }, ...opts]
    },
    // 已有 hy2 入站列表：按端口排序，用户数从客户端表里数出来。
    rows(): { id: number, tag: string, port: number, users: number, tls: string }[] {
      const clients = Data().clients || []
      return (Data().inbounds || [])
        .filter((i: any) => i.type === InTypes.Hysteria2)
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
    // -----------------------------------------------------------------
    async ensureTls(prefix: string): Promise<number> {
      if (this.form.tlsId > 0) return this.form.tlsId

      const sni = normalizeHost(this.form.sni) || currentHost() || 'www.bing.com'
      const msg = await HttpUtils.get<string[]>('api/keypairs', { k: 'tls', o: sni })
      if (!msg.success || !Array.isArray(msg.obj) || msg.obj.length == 0) {
        push.error({ message: i18n.global.t('hy2.noTls') })
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
        push.error({ message: i18n.global.t('hy2.noTls') })
        return 0
      }

      const tlsName = prefix + '-hy2-' + RandomUtil.randomLowerAndNum(4)
      const tls = {
        id: 0,
        name: tlsName,
        server: {
          enabled: true,
          server_name: sni,
          alpn: HY2_ALPN,
          certificate: cert,
          key: key,
        },
        client: {
          alpn: HY2_ALPN,
          // 自签证书只能靠 insecure 过，链接里会带 insecure=1
          insecure: true,
        },
      }
      if (!await Data().save('tls', 'new', tls)) return 0
      const saved = (Data().tlsConfigs || []).find((t: any) => t.name == tlsName)
      if (!saved?.id) {
        push.error({ message: i18n.global.t('hy2.noTls') })
        return 0
      }
      return saved.id
    },
    // -----------------------------------------------------------------
    // 一键创建：端口 → TLS → 逐个入站 → 每个入站的用户（addbulk）。
    // 用户凭据是 config.hysteria2 = {name, password}：hy2 按密码认证，
    // name 同时是 sing-box 侧的会话/统计标识，缺了流量统计会是空白。
    // -----------------------------------------------------------------
    async create() {
      const count = Math.min(Math.max(Math.floor(this.form.count) || 1, 1), 50)
      const perNode = Math.min(Math.max(Math.floor(this.form.perNode) || 1, 1), 50)
      const prefix = safeName(this.form.prefix) || 'hy2'

      const ports = this.allocPorts(count)
      if (ports.length < count) {
        push.error({ message: i18n.global.t('hy2.noPort') })
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
          //    缺了它们客户端链接就拼不出来。
          const inbound: any = createInbound(InTypes.Hysteria2, {
            id: 0, tag, listen: '::', listen_port: port, tls_id: tlsId,
          })
          if (this.form.obfs) {
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
            cfg.hysteria2 = { name: userName, password: RandomUtil.randomSeq(16) }
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
          this.result = { ok: false, text: i18n.global.t('hy2.fail', { list: failed.join(', ') }) }
          push.error({ message: this.result.text })
          return
        }

        const done = i18n.global.t('hy2.created', { n: tags.length, users })
        this.result = failed.length == 0
          ? { ok: true, text: done }
          : { ok: false, text: done + ' / ' + i18n.global.t('hy2.fail', { list: failed.join(', ') }) }
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
