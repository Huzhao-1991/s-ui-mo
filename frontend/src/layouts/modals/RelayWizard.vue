<template>
  <!-- ======================================================================
    添加中转向导（RelayWizard）
    --------------------------------------------------------------------
    三步创建一个中转：
      1. 解析「落地节点分享链接」 -> 得到一个 sing-box 出站对象
         - socks5 链接在前端直接解析（socks5:// 或 IP:端口[:用户:密码]）
         - 其它协议（vless/vmess/trojan/ss/hysteria2/tuic...）调后端
           api/linkConvert 转换（与出站页「从链接导入」同一接口）
      2. 起一个不冲突的 tag，把出站存进 outbounds
      3. 往 config.route.rules 追加一条 {inbound: [...], action: route,
         outbound: tag} 并保存（保存 config 会触发核心重启，出站与路由一起生效）
      4. 最后调 api/checkOutbound 探测落地连通性，把结果反馈给用户
    ====================================================================== -->
  <v-dialog transition="dialog-bottom-transition" width="640">
    <v-card class="rounded-lg" :loading="loading">
      <v-card-title>{{ $t('relay.title') }}</v-card-title>
      <v-divider />
      <v-card-text>
        <v-container style="padding: 0;">
          <p style="font-size: 0.85rem; opacity: 0.8; margin-bottom: 12px;">{{ $t('relay.desc') }}</p>
          <v-row>
            <v-col cols="12">
              <!-- 落地节点分享链接（vless://... 或 socks5 IP:端口:用户:密码） -->
              <v-textarea
                :label="$t('relay.link')"
                :hint="$t('relay.linkHint')"
                persistent-hint
                v-model="form.link"
                :rows="2"
                auto-grow
              />
            </v-col>
            <v-col cols="12" sm="6">
              <!-- 中转名称：留空则自动生成 relay-xxxxxx -->
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
          </v-row>
          <!-- 创建结果提示（成功/落地测试未通过） -->
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
        <v-btn color="primary" variant="tonal" :loading="loading" @click="createRelay">{{ $t('relay.create') }}</v-btn>
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

export default {
  props: ['visible'],
  emits: ['close'],
  data() {
    return {
      loading: false,
      form: { link: '', name: '', inbounds: <string[]>[] },
      result: <any>null,
    }
  },
  watch: {
    // 每次打开弹窗都重置表单，避免上一次的输入残留
    visible(v: boolean) {
      if (v) this.reset()
    },
  },
  computed: {
    // 可作为中转入口的入站 = 携带用户流量的入站（有 users 字段的）。
    // 纯转发的入站（比如落地机上的）不该再被转出去。
    inboundOptions(): string[] {
      return (Data().inbounds || [])
        .filter((i: any) => i.tag && i.users)
        .map((i: any) => i.tag)
    },
  },
  methods: {
    reset() {
      // 默认一个入口都不选。路由规则会把选中入站的出口整个改道到落地，
      // 如果默认全选，会把现有所有节点一次性都推到落地 IP 后面
      // （表现为"我原来的节点全变成中转的 IP 了"）。让用户自己挑。
      this.form = { link: '', name: '', inbounds: [] }
      this.result = null
      this.loading = false
    },
    closeModal() {
      this.$emit('close')
    },
    // -----------------------------------------------------------------
    // 前端直接解析 SOCKS5 落地，省一次后端往返。
    // 支持两种写法：
    //   socks5://[user:pass@]host:port
    //   IP:PORT 或 IP:PORT:USER:PASS（纯 IPv4）
    // 解析不出返回 null，交给后端 linkConvert 兜底。
    // -----------------------------------------------------------------
    parseSocks(raw: string): any | null {
      const uri = raw.match(/^socks5?:\/\/(?:([^:@/]+):([^@/]+)@)?\[?([^\]:/]+)\]?:(\d{1,5})\/?.*$/i)
      if (uri) {
        const ob: any = { type: 'socks', server: uri[3], server_port: parseInt(uri[4]), version: '5' }
        if (uri[1]) { ob.username = decodeURIComponent(uri[1]); ob.password = decodeURIComponent(uri[2]) }
        return ob
      }
      const parts = raw.split(':')
      if ((parts.length === 2 || parts.length === 4) && /^(\d{1,3}\.){3}\d{1,3}$/.test(parts[0])) {
        const port = parseInt(parts[1])
        if (!Number.isInteger(port) || port < 1 || port > 65535) return null
        const ob: any = { type: 'socks', server: parts[0], server_port: port, version: '5' }
        if (parts.length === 4) { ob.username = parts[2]; ob.password = parts[3] }
        return ob
      }
      return null
    },
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
        const base = (this.form.name || '').trim() || outbound.tag || ('relay-' + RandomUtil.randomLowerAndNum(6))
        const used = new Set<string>([
          ...(Data().outbounds || []).map((o: any) => o.tag),
          ...(Data().endpoints || []).map((e: any) => e.tag),
          ...(Data().inbounds || []).map((i: any) => i.tag),
        ])
        let tag = base
        let n = 1
        while (used.has(tag)) tag = base + '-' + (n++)
        outbound.tag = tag
        // id 是后端数据库字段，新建时不能带过去
        delete outbound.id

        // 3) 保存落地出站。
        if (!await Data().save('outbounds', 'new', outbound)) return

        // 4) 追加路由规则：入口入站 -> 该落地出站。
        const config = JSON.parse(JSON.stringify(Data().config || {}))
        if (!config.route) config.route = {}
        if (!Array.isArray(config.route.rules)) config.route.rules = []
        config.route.rules.push({ inbound: [...this.form.inbounds], action: 'route', outbound: tag })

        // 5) 保存完整 config（触发核心重启，出站与路由同时生效）。
        if (!await Data().save('config', 'set', config)) return

        // 6) 探测落地连通性，把结果展示在弹窗里。
        const test = await HttpUtils.get<{ OK: boolean; Delay?: number; Error?: string }>('api/checkOutbound', { tag })
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
  },
}
</script>
