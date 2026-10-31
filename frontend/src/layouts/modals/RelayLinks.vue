<template>
  <!-- ======================================================================
    中转节点链接（RelayLinks）
    --------------------------------------------------------------------
    中转对客户端是「入口入站」那一层协议，链接就是入口入站上那些用户的
    分享链接（后端 util/LinkGenerator 生成，这里只负责摊开、复制、扫码）。

    两种打开方式：
      - 向导建完站自动打开（created 事件带新建入站 tag）
      - 中转卡片上的「节点链接」按钮（带该中转的全部入口入站 tag）

    链接按客户端分组，每行一条，标注它属于哪个入口入站；
    支持单条复制 / 二维码 / 明文与 Base64 整包复制。
    ====================================================================== -->
  <v-dialog
    transition="dialog-bottom-transition"
    width="760"
    :model-value="visible"
    @update:model-value="(v: boolean) => { if (!v) $emit('close') }"
  >
    <v-card class="rounded-lg" id="relay-links-modal" :loading="loading">
      <v-card-title>
        <v-row>
          <v-col>
            {{ heading || $t('relay.linksTitle') }}
            <span v-if="title" style="font-size: 0.8rem; opacity: 0.6;">· {{ title }}</span>
          </v-col>
          <v-spacer />
          <v-col cols="auto"><v-icon icon="mdi-close-box" @click="$emit('close')" /></v-col>
        </v-row>
      </v-card-title>
      <v-divider />
      <v-card-text>
        <!-- heading / desc 可选：中转页用默认文案，「一键 Hy2」页面传自己的措辞 -->
        <p style="font-size: 0.85rem; opacity: 0.8; margin-bottom: 4px;">{{ desc || $t('relay.linksDesc') }}</p>
        <p v-if="tagsText" style="font-size: 0.8rem; opacity: 0.7; margin-bottom: 10px;">
          {{ $t('relay.linksEntry') }}: {{ tagsText }}
        </p>

        <div v-if="total === 0" style="text-align: center; opacity: 0.6; padding: 24px;">
          {{ $t('relay.linksEmpty') }}
        </div>

        <template v-else>
          <v-btn-toggle
            v-model="format"
            mandatory
            density="compact"
            variant="outlined"
            color="primary"
            style="margin-bottom: 10px;"
          >
            <v-btn value="plain" size="small">{{ $t('relay.plain') }}</v-btn>
            <v-btn value="base64" size="small">{{ $t('relay.base64') }}</v-btn>
          </v-btn-toggle>

          <v-card
            v-for="g in groups"
            :key="g.name"
            variant="outlined"
            class="rounded-lg"
            style="margin-bottom: 12px; padding: 12px;"
          >
            <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
              <v-chip size="small" color="primary">{{ g.name }}</v-chip>
              <span style="font-size: 0.76rem; opacity: 0.7;">{{ g.links.length }}</span>
            </div>
            <div v-for="(l, i) in g.links" :key="i" style="margin-top: 8px;">
              <div style="display: flex; align-items: center; gap: 8px;">
                <v-chip size="x-small" label variant="tonal" style="flex: 0 0 auto;">{{ l.remark }}</v-chip>
                <v-text-field
                  :model-value="l.uri"
                  readonly
                  density="compact"
                  hide-details
                  variant="outlined"
                  append-inner-icon="mdi-content-copy"
                  @click:append-inner="copy(l.uri)"
                  style="font-size: 0.74rem;"
                />
                <v-icon
                  :icon="qrKey === g.name + ':' + i ? 'mdi-qrcode-remove' : 'mdi-qrcode'"
                  size="small"
                  style="cursor: pointer;"
                  @click="toggleQr(g.name, i)"
                />
              </div>
              <div v-if="qrKey === g.name + ':' + i" style="text-align: center; margin-top: 8px;">
                <QrcodeVue :value="l.uri" :size="170" :margin="1" style="border-radius: 10px; cursor: copy;" @click="copy(l.uri)" />
              </div>
            </div>
          </v-card>

          <v-textarea
            :model-value="displayText"
            :rows="4"
            readonly
            variant="outlined"
            hide-details
            style="font-family: monospace; font-size: 0.74rem;"
          />
          <div style="text-align: end; margin-top: 10px;">
            <span style="font-size: 0.8rem; opacity: 0.7; margin-inline-end: 10px;">{{ $t('relay.linksCount', { n: total }) }}</span>
            <v-btn color="primary" variant="tonal" @click="copy(displayText)">{{ $t('relay.copyAll') }}</v-btn>
          </div>
        </template>
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
import Clipboard from 'clipboard'
import Data from '@/store/modules/data'
import HttpUtils from '@/plugins/httputil'
import { i18n } from '@/locales'
import { push } from 'notivue'

export default {
  props: ['visible', 'inboundTags', 'title', 'heading', 'desc'],
  emits: ['close'],
  components: { QrcodeVue },
  data() {
    return {
      loading: false,
      groups: <any[]>[],      // [{ name, links: [{ remark, uri }] }]
      format: 'plain',        // plain 明文 | base64 整包
      qrKey: '',              // 当前展开二维码的那一条：<客户端名>:<序号>
    }
  },
  watch: {
    visible(v: boolean) {
      if (v) this.load()
    },
  },
  computed: {
    tags(): string[] {
      return <string[]>(this.inboundTags || [])
    },
    tagsText(): string {
      return this.tags.join(', ')
    },
    total(): number {
      return this.groups.reduce((n: number, g: any) => n + g.links.length, 0)
    },
    allText(): string {
      const lines: string[] = []
      this.groups.forEach((g: any) => g.links.forEach((l: any) => lines.push(l.uri)))
      return lines.join('\n')
    },
    // Base64 整包：remark 里可能有中文，直接 btoa 会抛异常，先 encodeURIComponent
    displayText(): string {
      if (this.format === 'base64' && this.allText) {
        try {
          return btoa(unescape(encodeURIComponent(this.allText)))
        } catch {
          return this.allText
        }
      }
      return this.allText
    },
  },
  methods: {
    // 入口入站的 tag -> id -> 挂在上面的客户端 -> 一次请求取回完整行（带 links）。
    // 链接的 remark 就是入站 tag（后端的 JoinRemark：<客户端备注>-<入站 tag>），
    // 所以按 tag 过滤时用后缀匹配，客户端自己带备注也能认出来。
    matchTag(remark: string): boolean {
      const tags = this.tags
      if (tags.length === 0) return true
      const r = remark || ''
      return tags.some((t: string) => r === t || r.endsWith('-' + t))
    },
    async load() {
      this.loading = true
      this.groups = []
      this.format = 'plain'
      this.qrKey = ''
      const tags = this.tags
      const inboundIds = (Data().inbounds || [])
        .filter((i: any) => tags.length === 0 || tags.includes(i.tag))
        .map((i: any) => i.id)
      const ids = (Data().clients || [])
        .filter((c: any) => Array.isArray(c.inbounds) && c.inbounds.some((id: number) => inboundIds.includes(id)))
        .map((c: any) => c.id)
      if (ids.length > 0) {
        const msg = await HttpUtils.get<{ clients?: any[] }>('api/clients', { id: ids.join(',') })
        if (msg.success && msg.obj?.clients) {
          this.groups = msg.obj.clients
            .map((c: any) => ({
              name: c.name,
              links: (c.links || []).filter((l: any) => l && l.uri && l.type !== 'sub' && this.matchTag(l.remark)),
            }))
            .filter((g: any) => g.links.length > 0)
        }
      }
      this.loading = false
    },
    toggleQr(name: string, index: string | number) {
      const key = name + ':' + index
      this.qrKey = this.qrKey === key ? '' : key
    },
    // 复制到剪贴板。clipboard 库要求从一个真实 DOM 元素上触发，
    // 所以这里临时创建一个隐藏按钮，点击后立刻销毁。
    copy(txt: string) {
      if (!txt) return
      const hiddenButton = document.createElement('button')
      hiddenButton.className = 'relay-clipboard-btn'
      document.body.appendChild(hiddenButton)

      const clipboard = new Clipboard('.relay-clipboard-btn', {
        text: () => txt,
        container: document.getElementById('relay-links-modal') ?? undefined,
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
}
</script>
