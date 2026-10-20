<template>
  <!-- ======================================================================
    导出选中用户的 vless 链接（ClientLinks）
    --------------------------------------------------------------------
    用户管理页勾选若干用户 -> 一次请求取回这些用户的完整行（带 links） ->
    只留本机入站生成的 vless 链接，一行一条，整块复制即可粘进客户端的
    "从剪贴板导入批量URL"。

    两条筛选，都不靠猜：
      - type === 'local'：后端 updateLinksWithFixedInbounds 给本机入站生成的
        链接打的标记（remark 存的是入站 tag）。用户自己添加的外部链接、订阅
        都不是 local，导出它们等于把别人的凭据发出去。
      - uri 以 vless:// 开头：批量建站生成的入口入站本来就是 vless + reality，
        reality 体现在 URI 的 security=reality 参数上，不在协议名里，所以按
        前缀筛 vless 而不是找 "reality://"。socks 那类落地链接自然被排除。
    ====================================================================== -->
  <v-dialog transition="dialog-bottom-transition" width="760">
    <v-card
      class="rounded-lg"
      id="client-links-modal"
      :loading="loading"
    >
      <v-card-title>
        <v-row>
          <v-col>{{ $t('client.exportTitle') }}</v-col>
          <v-spacer />
          <v-col cols="auto">
            <v-icon
              icon="mdi-close-box"
              @click="$emit('close')"
            />
          </v-col>
        </v-row>
      </v-card-title>
      <v-divider />
      <v-card-text>
        <p style="font-size: 0.85rem; opacity: 0.8; margin-bottom: 12px;">
          {{ $t('client.exportHint') }}
        </p>
        <v-textarea
          :model-value="text"
          :rows="12"
          readonly
          variant="outlined"
          hide-details
          :placeholder="$t('client.exportEmpty')"
          style="font-family: monospace; font-size: 0.78rem;"
        />
        <div style="text-align: end; margin-top: 10px;">
          <span style="font-size: 0.8rem; opacity: 0.7; margin-inline-end: 10px;">
            {{ $t('client.linksCount', { n: count }) }}
          </span>
          <v-btn
            color="primary"
            variant="tonal"
            :disabled="!text"
            @click="copy(text)"
          >
            {{ $t('exportLinks.copy') }}
          </v-btn>
        </div>
      </v-card-text>
      <v-card-actions>
        <v-spacer />
        <v-btn
          color="primary"
          variant="outlined"
          @click="$emit('close')"
        >
          {{ $t('actions.close') }}
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script lang="ts">
import HttpUtils from '@/plugins/httputil'
import Clipboard from 'clipboard'
import { i18n } from '@/locales'
import { push } from 'notivue'

export default {
  props: ['visible', 'clientIds'],
  emits: ['close'],
  data() {
    return {
      loading: false,
      text: '',   // 明文链接，一行一条
      count: 0,   // 条数
    }
  },
  watch: {
    // 每次打开都重新拉，导出的一定是当前状态
    visible(v: boolean) {
      if (v) this.load()
    },
  },
  methods: {
    async load() {
      this.loading = true
      this.text = ''
      this.count = 0

      const ids = (this.clientIds ?? []).filter((x: number) => x)
      if (ids.length > 0) {
        const msg = await HttpUtils.get<{ clients?: any[] }>('api/clients', { id: ids.join(',') })
        if (msg.success && msg.obj?.clients) {
          const uris: string[] = []
          msg.obj.clients.forEach((c: any) => {
            (c.links ?? []).forEach((l: any) => {
              if (l.type === 'local' && (l.uri ?? '').startsWith('vless://')) uris.push(l.uri)
            })
          })
          this.text = uris.join('\n')
          this.count = uris.length
        }
      }
      this.loading = false
    },
    // 复制到剪贴板。clipboard 库要求从真实 DOM 元素触发，
    // 所以临时建一个隐藏按钮，点击后立刻销毁。
    copy(txt: string) {
      if (!txt) return
      const hiddenButton = document.createElement('button')
      hiddenButton.className = 'client-links-clipboard-btn'
      document.body.appendChild(hiddenButton)

      const clipboard = new Clipboard('.client-links-clipboard-btn', {
        text: () => txt,
        container: document.getElementById('client-links-modal') ?? undefined,
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
