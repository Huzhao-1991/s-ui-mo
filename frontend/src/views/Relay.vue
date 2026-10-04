<template>
  <!-- ======================================================================
    中转管理（Relay）
    --------------------------------------------------------------------
    「中转」在本面板里不是一个独立的数据模型，而是一组既有对象的组合：
      1. 一个「落地出站」outbound（流量最终从哪个节点出去）
      2. 一条「路由规则」route rule（action: route，inbound -> outbound）
    只要一条路由规则的 outbound 指向一个真实出站，它就是一个中转。
    本页面把这些组合从 config.route.rules + outbounds 里"算"出来展示，
    并提供向导式创建 / 单个删除 / 全部删除 / 落地测速 / 客户端二维码。

    后端无需任何新接口，全部复用：
      - api/save    object=config   （改路由规则，会触发核心重启）
      - api/save    object=outbounds（增删落地出站）
      - api/checkOutbound ?tag=     （对落地出站做一次连通性测速）
    ====================================================================== -->
  <RelayWizard
    v-model="wizardModal"
    :visible="wizardModal"
    @close="wizardModal = false"
  />
  <!-- 中转对用户是透明的：用户连的还是入口入站上的客户端，
       所以"中转的二维码"就是入口入站上那些客户端的二维码 -->
  <QrCode
    v-model="qrcode.visible"
    :visible="qrcode.visible"
    :id="qrcode.id"
    @close="qrcode.visible = false"
  />
  <!-- 一个入口入站上挂了多个客户端时，先让用户挑一个再出二维码 -->
  <v-dialog v-model="picker.visible" width="320">
    <v-card class="rounded-lg" :title="$t('pages.clients')">
      <v-divider />
      <v-list density="compact" nav>
        <v-list-item v-for="c in picker.clients" :key="c.id" link @click="pickClient(c.id)">
          <template #prepend><v-icon icon="mdi-qrcode" /></template>
          <v-list-item-title>{{ c.name }}</v-list-item-title>
        </v-list-item>
      </v-list>
    </v-card>
  </v-dialog>
  <ExportLinks
    v-model="exportModal"
    :visible="exportModal"
    @close="exportModal = false"
  />
  <!-- 「全部删除」是不可逆操作，先弹确认框 -->
  <v-dialog v-model="clearConfirm" width="380">
    <v-card class="rounded-lg" :title="$t('relay.clearAll')">
      <v-divider />
      <v-card-text>{{ $t('relay.clearAllConfirm') }}</v-card-text>
      <v-card-actions>
        <v-spacer />
        <v-btn color="success" variant="outlined" @click="clearConfirm = false">{{ $t('no') }}</v-btn>
        <v-btn color="error" variant="tonal" :loading="clearLoading" @click="clearAllRelays">{{ $t('yes') }}</v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
  <!-- 页面顶部操作区：添加中转 / 导出 / 全部删除 -->
  <v-row justify="center" align="center">
    <v-col cols="auto">
      <v-btn color="primary" prepend-icon="mdi-transit-connection-variant" @click="wizardModal = true">{{ $t('relay.btn') }}</v-btn>
    </v-col>
    <v-col cols="auto">
      <v-btn color="primary" variant="tonal" prepend-icon="mdi-export-variant" @click="exportModal = true">{{ $t('exportLinks.btn') }}</v-btn>
    </v-col>
    <v-col cols="auto" v-if="relays.length > 0">
      <v-btn color="error" variant="tonal" prepend-icon="mdi-delete-sweep" :loading="clearLoading" @click="clearConfirm = true">{{ $t('relay.clearAll') }}</v-btn>
    </v-col>
  </v-row>
  <!-- 空状态提示 -->
  <v-row v-if="relays.length === 0">
    <v-col cols="12" style="text-align: center; opacity: 0.6; margin-top: 30px;">{{ $t('relay.empty') }}</v-col>
  </v-row>
  <!-- 中转卡片列表：一张卡 = 一个落地出站 + 它的入口入站集合 -->
  <v-row>
    <v-col cols="12" sm="6" md="4" lg="3" v-for="(r, index) in relays" :key="r.outbound">
      <v-card rounded="xl" elevation="5" min-width="200" :title="r.outbound">
        <v-card-subtitle style="margin-top: -15px;">{{ r.type }} · {{ r.server }}</v-card-subtitle>
        <v-card-text>
          <v-row>
            <!-- 入口：哪些入站（节点）的流量会走这个落地 -->
            <v-col cols="4">{{ $t('relay.entry') }}</v-col>
            <v-col cols="8">
              <v-chip v-for="t in r.inbounds" :key="t" size="x-small" label class="ma-1">{{ t }}</v-chip>
            </v-col>
          </v-row>
          <v-row>
            <!-- 落地测速：点速度计图标对落地出站发一次探测 -->
            <v-col cols="4">{{ $t('out.delay') }}</v-col>
            <v-col cols="8">
              <v-progress-circular v-if="checkResults[r.outbound]?.loading" indeterminate size="20" />
              <v-icon v-else icon="mdi-speedometer" @click="checkOutbound(r.outbound)">
                <v-tooltip activator="parent" location="top" :text="$t('actions.test')" />
              </v-icon>
              <v-chip v-if="checkResults[r.outbound] && !checkResults[r.outbound].loading && checkResults[r.outbound].success"
                density="compact" size="small" color="success" variant="flat" class="ms-1">
                {{ checkResults[r.outbound].data?.Delay + $t('date.ms') }}
              </v-chip>
              <v-icon v-else-if="checkResults[r.outbound] && !checkResults[r.outbound].loading"
                size="small" color="error" icon="mdi-close-circle" class="ms-1" />
            </v-col>
          </v-row>
        </v-card-text>
        <v-divider />
        <v-card-actions style="padding: 0;">
          <!-- 二维码：给出入口入站上客户端的链接（用户实际连接用的） -->
          <v-btn icon="mdi-qrcode" @click="showRelayQr(r)">
            <v-icon />
            <v-tooltip activator="parent" location="top" :text="$t('client.links')" />
          </v-btn>
          <!-- 删除：点图标后弹出二次确认覆盖层 -->
          <v-btn icon="mdi-file-remove" color="warning" @click="delOverlay[index] = true">
            <v-icon />
            <v-tooltip activator="parent" location="top" :text="$t('actions.del')" />
          </v-btn>
          <v-overlay v-model="delOverlay[index]" contained class="align-center justify-center">
            <v-card :title="$t('actions.del')" rounded="lg">
              <v-divider />
              <v-card-text>{{ $t('relay.delConfirm') }}</v-card-text>
              <v-card-actions>
                <v-btn color="error" variant="outlined" :loading="delLoading" @click="delRelay(r, index)">{{ $t('yes') }}</v-btn>
                <v-btn color="success" variant="outlined" @click="delOverlay[index] = false">{{ $t('no') }}</v-btn>
              </v-card-actions>
            </v-card>
          </v-overlay>
        </v-card-actions>
      </v-card>
    </v-col>
  </v-row>
</template>

<script lang="ts" setup>
// ---------------------------------------------------------------------------
// 中转管理页面
// 复用与出站页一致的 checkOutbound 数据结构，保证两处展示行为一致。
// ---------------------------------------------------------------------------
import Data from '@/store/modules/data'
import HttpUtils from '@/plugins/httputil'
import RelayWizard from '@/layouts/modals/RelayWizard.vue'
import QrCode from '@/layouts/modals/QrCode.vue'
import ExportLinks from '@/layouts/modals/ExportLinks.vue'
import { computed, ref } from 'vue'

const wizardModal = ref(false)   // 「添加中转」向导弹窗
const exportModal = ref(false)   // 「导出链接」弹窗
const delOverlay = ref<boolean[]>([]) // 每张卡独立的删除确认覆盖层
const delLoading = ref(false)
const clearConfirm = ref(false)  // 「全部删除」确认框
const clearLoading = ref(false)
const checkResults = ref<Record<string, any>>({}) // 落地测速结果，按出站 tag 索引

// 二维码弹窗：id 是客户端 id；入口入站上若只有一个客户端就直接出，
// 多个则先弹选择列表（picker）
const qrcode = ref({ visible: false, id: 0 })
const picker = ref({ visible: false, clients: <any[]>[] })

// 找出某个中转的入口入站上挂的所有客户端：
//   入站 tag -> 入站 id -> clients 里 inbounds 包含该 id 的客户端
const clientsForRelay = (r: any): any[] => {
  const entryIds = (Data().inbounds || []).filter((i: any) => r.inbounds.includes(i.tag)).map((i: any) => i.id)
  return (Data().clients || []).filter((c: any) => Array.isArray(c.inbounds) && c.inbounds.some((id: number) => entryIds.includes(id)))
}
const showRelayQr = (r: any) => {
  const cls = clientsForRelay(r)
  if (cls.length === 0) return
  if (cls.length === 1) {
    // 只有一个客户端：直接出它的二维码
    qrcode.value.id = cls[0].id
    qrcode.value.visible = true
    return
  }
  // 多个客户端：先弹列表让用户挑
  picker.value.clients = cls
  picker.value.visible = true
}
const pickClient = (id: number) => {
  picker.value.visible = false
  qrcode.value.id = id
  qrcode.value.visible = true
}

// ---------------------------------------------------------------------------
// 中转列表（计算属性）：每次 config / outbounds 变化都会重算。
// 判定标准：一条 route 规则的 action === 'route' 且 outbound 指向真实出站。
// ---------------------------------------------------------------------------
const relays = computed((): any[] => {
  const config: any = Data().config || {}
  const rules: any[] = config.route?.rules || []
  const obs: any[] = Data().outbounds || []
  const result: any[] = []
  rules.forEach((rule: any) => {
    if (rule && rule.action === 'route' && rule.outbound && rule.inbound) {
      const ob = obs.find((o: any) => o.tag === rule.outbound)
      if (ob) {
        result.push({
          outbound: ob.tag,
          type: ob.type,
          server: ob.server ?? '-',
          // 规则里的 inbound 可能是字符串或数组，统一成数组展示
          inbounds: Array.isArray(rule.inbound) ? rule.inbound : [rule.inbound],
        })
      }
    }
  })
  return result
})

// 落地测速：与出站页同一接口（api/checkOutbound），15 秒内返回延迟或错误
const checkOutbound = async (tag: string) => {
  checkResults.value = { ...checkResults.value, [tag]: { loading: true, success: false } }
  const msg = await HttpUtils.get<{ OK: boolean; Delay?: number; Error?: string }>('api/checkOutbound', { tag })
  const success = msg.success && msg.obj?.OK
  checkResults.value = { ...checkResults.value, [tag]: { loading: false, success, data: msg.obj ?? null } }
}

// ---------------------------------------------------------------------------
// 删除一个中转 = 两步，顺序不能反：
//   1) 先把指向该落地的路由规则从 config 里去掉并保存（会触发核心重启）
//   2) 再删掉落地出站本身
// 若先删出站，路由规则会短暂指向一个不存在的出站，核心可能起不来。
// ---------------------------------------------------------------------------
const delRelay = async (r: any, index: number) => {
  delLoading.value = true
  // 1) 深拷贝当前 config，过滤掉所有 action=route 且 outbound 指向该落地的规则
  const config = JSON.parse(JSON.stringify(Data().config || {}))
  if (config.route?.rules) {
    config.route.rules = config.route.rules.filter(
      (rule: any) => !(rule.action === 'route' && rule.outbound === r.outbound)
    )
  }
  await Data().save('config', 'set', config)
  // 2) 删除落地出站
  await Data().save('outbounds', 'del', r.outbound)
  delLoading.value = false
  delOverlay.value[index] = false
}

// 全部删除：一次 config 保存去掉所有中转规则，再逐个删落地出站
const clearAllRelays = async () => {
  clearLoading.value = true
  const tags = relays.value.map((r: any) => r.outbound)
  const config = JSON.parse(JSON.stringify(Data().config || {}))
  if (config.route?.rules) {
    config.route.rules = config.route.rules.filter(
      (rule: any) => !(rule.action === 'route' && tags.includes(rule.outbound))
    )
  }
  await Data().save('config', 'set', config)
  for (const tag of tags) {
    await Data().save('outbounds', 'del', tag)
  }
  clearLoading.value = false
  clearConfirm.value = false
}
</script>
