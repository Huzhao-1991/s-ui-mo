<template>
  <!-- ======================================================================
    导出链接（ExportLinks）
    --------------------------------------------------------------------
    把面板里所有客户端的连接信息导出给外部客户端工具用，两个页签：
      - 订阅：每个客户端一条订阅 URL（加一次自动更新，推荐）
      - 全部链接：所有分享链接逐行排列，可明文或 Base64 整包复制，
        直接粘进 v2rayN 的"从剪贴板导入批量URL"
    数据来源：
      - 订阅地址 = store 里的 subURI（面板订阅根路径）+ 客户端名
      - 全部链接 = api/clients?id=1,2,3 一次性取回带 links 的完整行
    ====================================================================== -->
  <v-dialog transition="dialog-bottom-transition" width="760">
    <v-card class="rounded-lg" id="export-links-modal" :loading="loading">
      <v-card-title>
        <v-row>
          <v-col>{{ $t('exportLinks.title') }}</v-col>
          <v-spacer />
          <v-col cols="auto"><v-icon icon="mdi-close-box" @click="$emit('close')" /></v-col>
        </v-row>
      </v-card-title>
      <v-divider />
      <v-tabs v-model="tab" density="compact" fixed-tabs align-tabs="center">
        <v-tab value="sub">{{ $t('exportLinks.subTab') }}</v-tab>
        <v-tab value="links">{{ $t('exportLinks.linksTab') }}</v-tab>
      </v-tabs>
      <v-card-text>
        <v-window v-model="tab" style="margin-top: 6px;">
          <!-- 页签一：订阅 URL，一客户端一条，点二维码或输入框即复制 -->
          <v-window-item value="sub">
            <p style="font-size: 0.85rem; opacity: 0.8; margin-bottom: 12px;">{{ $t('exportLinks.subDesc') }}</p>
            <div v-if="subList.length === 0" style="text-align: center; opacity: 0.6; padding: 20px;">{{ $t('exportLinks.empty') }}</div>
            <v-card v-for="s in subList" :key="s.name" variant="outlined" class="rounded-lg" style="margin-bottom: 14px; padding: 12px;">
              <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 10px;">
                <v-chip size="small" color="primary">{{ s.name }}</v-chip>
                <v-text-field
                  :model-value="s.uri"
                  readonly
                  density="compact"
                  hide-details
                  variant="outlined"
                  append-inner-icon="mdi-content-copy"
                  @click:append-inner="copy(s.uri)"
                  style="font-size: 0.76rem;"
                />
              </div>
              <div style="text-align: center;">
                <QrcodeVue :value="s.uri" :size="180" :margin="1" @click="copy(s.uri)" style="border-radius: 10px; cursor: copy;" />
              </div>
            </v-card>
          </v-window-item>
          <!-- 页签二：全部分享链接，支持明文 / Base64 整包 -->
          <v-window-item value="links">
            <p style="font-size: 0.85rem; opacity: 0.8; margin-bottom: 10px;">{{ $t('exportLinks.desc') }}</p>
            <v-btn-toggle
              v-model="format"
              mandatory
              density="compact"
              variant="outlined"
              color="primary"
              style="margin-bottom: 10px;"
            >
              <v-btn value="plain" size="small">{{ $t('exportLinks.plain') }}</v-btn>
              <v-btn value="base64" size="small">{{ $t('exportLinks.base64') }}</v-btn>
            </v-btn-toggle>
            <p v-if="format === 'base64'" style="font-size: 0.8rem; opacity: 0.7; margin-bottom: 8px;">{{ $t('exportLinks.base64Hint') }}</p>
            <v-textarea
              :model-value="displayText"
              :rows="10"
              readonly
              variant="outlined"
              hide-details
              :placeholder="$t('exportLinks.empty')"
              style="font-family: monospace; font-size: 0.78rem;"
            />
            <div style="text-align: end; margin-top: 10px;">
              <span style="font-size: 0.8rem; opacity: 0.7; margin-inline-end: 10px;">{{ count }}</span>
              <v-btn color="primary" variant="tonal" :disabled="!text" @click="copy(displayText)">{{ $t('exportLinks.copy') }}</v-btn>
            </div>
          </v-window-item>
        </v-window>
      </v-card-text>
      <v-card-actions>
        <v-spacer />
        <v-btn color="primary" variant="outlined" @click="$emit('close')">{{ $t('actions.close') }}</v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script lang="ts">
import QrcodeVue from 'qrcode.vue'
import Data from '@/store/modules/data'
import HttpUtils from '@/plugins/httputil'
import Clipboard from 'clipboard'
import { i18n } from '@/locales'
import { push } from 'notivue'

export default {
  props: ['visible'],
  emits: ['close'],
  data() {
    return {
      loading: false,
      tab: 'sub',        // 当前页签：sub（订阅）| links（全部链接）
      text: '',          // 全部链接的原始文本（每行一条）
      count: 0,          // 链接条数，展示在复制按钮旁
      format: 'plain',   // 导出格式：plain 明文 | base64 整包
      subList: <any[]>[], // 订阅列表 [{name, uri}]
    }
  },
  watch: {
    // 每次打开都重新拉数据，保证导出的是最新状态
    visible(v: boolean) {
      if (v) this.load()
    },
  },
  computed: {
    // base64 模式下做 UTF-8 安全编码：链接的 remark 里可能有中文，
    // 直接 btoa() 会抛异常，必须先 encodeURIComponent
    displayText(): string {
      if (this.format === 'base64' && this.text) {
        try {
          return btoa(unescape(encodeURIComponent(this.text)))
        } catch {
          return this.text
        }
      }
      return this.text
    },
  },
  methods: {
    async load() {
      this.loading = true
      this.tab = 'sub'
      this.format = 'plain'
      this.text = ''
      this.count = 0

      // 订阅 URL：一个客户端一条（覆盖它的全部协议，且自动更新）。
      // subURI 来自面板设置（订阅根路径，形如 http://host:port/sub/）。
      const subBase = Data().subURI
      this.subList = Data().clients.map((c: any) => ({ name: c.name, uri: subBase + c.name }))

      // 全部链接：一次请求取回完整客户端行（带 links 数组），
      // 过滤掉 type === 'sub' 的项（那是订阅链接，不是分享链接）。
      const ids = Data().clients.map((c: any) => c.id).filter((x: any) => x)
      if (ids.length > 0) {
        const msg = await HttpUtils.get<{ clients?: any[] }>('api/clients', { id: ids.join(',') })
        if (msg.success && msg.obj?.clients) {
          const uris: string[] = []
          msg.obj.clients.forEach((c: any) => {
            (c.links || []).forEach((l: any) => {
              if (l.type !== 'sub' && l.uri) uris.push(l.uri)
            })
          })
          this.text = uris.join('\n')
          this.count = uris.length
        }
      }
      this.loading = false
    },
    // 复制到剪贴板。clipboard 库要求从一个真实 DOM 元素上触发，
    // 所以这里临时创建一个隐藏按钮，点击后立刻销毁。
    copy(txt: string) {
      if (!txt) return
      const hiddenButton = document.createElement('button')
      hiddenButton.className = 'export-clipboard-btn'
      document.body.appendChild(hiddenButton)

      const clipboard = new Clipboard('.export-clipboard-btn', {
        text: () => txt,
        container: document.getElementById('export-links-modal') ?? undefined,
      })

      clipboard.on('success', () => {
        clipboard.destroy()
        push.success({
          message: i18n.global.t('success') + ': ' + i18n.global.t('copyToClipboard'),
          duration: 3000,
        })
      })
      clipboard.on('error', () => {
        clipboard.destroy()
        push.error({
          message: i18n.global.t('failed') + ': ' + i18n.global.t('copyToClipboard'),
          duration: 3000,
        })
      })

      hiddenButton.click()
      document.body.removeChild(hiddenButton)
    },
  },
  components: { QrcodeVue },
}
</script>
