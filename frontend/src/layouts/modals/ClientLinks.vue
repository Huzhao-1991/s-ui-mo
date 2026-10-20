<template>
  <!-- ======================================================================
    导出选中用户的 vless 链接（ClientLinks）
    --------------------------------------------------------------------
    用户管理页勾选若干用户 -> 一次请求取回这些用户的完整行（带 links） ->
    只留本机入站生成的 vless 链接，按用户分块展示：一块一个用户，块内一行一条，
    既能单独复制某个人，也能「复制全部」拿走整批。

    为什么分块：一堆纯链接看不出哪条是谁的，挑人给链接时只能靠猜。
    分块之后「哪个用户 -> 哪几条」是一眼的事。

    两条筛选，都不靠猜：
      - type === 'local'：后端 updateLinksWithFixedInbounds 给本机入站生成的
        链接打的标记（同一处写入的 remark 是入站 tag）。用户自己添加的外部
        链接、订阅都不是 local，导出它们等于把别人的凭据发出去。
      - uri 以 vless:// 开头：批量建站生成的入口入站本来就是 vless + reality，
        reality 体现在 URI 的 security=reality 参数上、不在协议名里，所以按
        前缀筛 vless 而不是找并不存在的 reality://。落地的 socks 链接本来
        就不是 vless，顺带被排除。
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
        <div
          v-if="groups.length === 0"
          style="text-align: center; opacity: 0.6; padding: 24px;"
        >
          {{ $t('client.exportEmpty') }}
        </div>
        <v-card
          v-for="g in groups"
          :key="g.name"
          variant="outlined"
          class="rounded-lg"
          style="margin-bottom: 12px; padding: 12px;"
        >
          <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
            <v-chip
              size="small"
              color="primary"
            >
              {{ g.name }}
            </v-chip>
            <span style="font-size: 0.8rem; opacity: 0.7;">
              {{ $t('client.linksCount', { n: g.links.length }) }}
            </span>
            <v-spacer />
            <v-btn
              size="small"
              variant="text"
              prepend-icon="mdi-content-copy"
              @click="copy(g.links.join('\n'))"
            >
              {{ $t('client.copyUser') }}
            </v-btn>
          </div>
          <v-text-field
            v-for="(u, i) in g.links"
            :key="i"
            :model-value="u"
            readonly
            density="compact"
            hide-details
            variant="outlined"
            append-inner-icon="mdi-content-copy"
            style="font-size: 0.74rem; margin-bottom: 6px;"
            @click:append-inner="copy(u)"
          />
        </v-card>
        <div style="text-align: end; margin-top: 10px;">
          <span style="font-size: 0.8rem; opacity: 0.7; margin-inline-end: 10px;">
            {{ $t('client.exportSummary', { u: groups.length, n: count }) }}
          </span>
          <v-btn
            color="primary"
            variant="tonal"
            :disabled="!text"
            @click="copy(text)"
          >
            {{ $t('client.copyAll') }}
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
      groups: <{ name: string, links: string[] }[]>[], // 一个用户一块，块内是他自己的链接
    }
  },
  computed: {
    // 全部链接拼起来（一行一条），「复制全部」拿的就是这个，
    // 可以直接粘进客户端的批量导入。
    text(): string {
      return this.groups.map((g: { links: string[] }) => g.links.join('\n')).join('\n')
    },
    count(): number {
      return this.groups.reduce((n: number, g: { links: string[] }) => n + g.links.length, 0)
    },
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
      this.groups = []

      const ids = (this.clientIds ?? []).filter((x: number) => x)
      if (ids.length > 0) {
        const msg = await HttpUtils.get<{ clients?: any[] }>('api/clients', { id: ids.join(',') })
        if (msg.success && msg.obj?.clients) {
          const groups: { name: string, links: string[] }[] = []
          msg.obj.clients.forEach((c: any) => {
            const links: string[] = []
            ;(c.links ?? []).forEach((l: any) => {
              if (l.type === 'local' && (l.uri ?? '').startsWith('vless://')) links.push(l.uri)
            })
            // 一条都没有的用户也列出来，否则「我明明勾了他却没出现」会以为漏了
            groups.push({ name: c.name, links: links })
          })
          this.groups = groups
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
