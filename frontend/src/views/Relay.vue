<template>
  <!-- ======================================================================
    中转管理（Relay）
    --------------------------------------------------------------------
    「中转」在本面板里不是一个独立的数据模型，而是一组既有对象的组合：
      1. 一个「落地出站」outbound（流量最终从哪个节点出去）
      2. 一组「路由规则」route rule（action: route，inbound + auth_user -> outbound）
    只要一条路由规则的 outbound 指向一个真实出站，它就属于一个中转。

    规则有两种形态，本页面两种都认：
      按用户   {inbound, auth_user:[用户名], action:'route', outbound}
               只有列出的用户走这个落地 —— 这就是「入站 + 用户 + 出站」
               三项在路由列表里关联起来的形态，在「路由列表」页看得见、改得动。
      整条入站 {inbound, action:'route', outbound}
               不限用户，整个入站的流量都走（旧版只有这一种；现在只在
               「建中转时一个用户都没选」时作为回退，也可一键转成按用户）。

    因为按用户分流时一个落地对应多条规则，本页面把规则按 outbound 聚合成
    一张卡，而不是一条规则一张卡。

    本页面把这些组合从 config.route.rules + outbounds 里"算"出来展示，
    并提供向导式创建 / 单个删除 / 全部删除 / 落地测速 / 用户管理 / 客户端二维码。

    后端无需任何新接口，全部复用：
      - api/save    object=config   （改路由规则，会触发核心重启）
      - api/save    object=outbounds（增删落地出站）
      - api/save    object=clients  （增删改中转的用户，见 RelayUsers.vue）
      - api/checkOutbound ?tag=     （对落地出站做一次连通性测速）
    ====================================================================== -->
  <RelayWizard
    v-model="wizardModal"
    :visible="wizardModal"
    @close="wizardModal = false"
  />
  <!-- 中转的用户 = 入口入站上的客户端 + 路由规则里的 auth_user 名单。
       用户弹窗见 RelayUsers.vue；「转为按用户」在弹窗里发起、由本页统一执行 -->
  <RelayUsers
    :visible="users.visible"
    :entry-tags="users.entryTags"
    :name="users.name"
    @close="users.visible = false"
    @convert="convertByName(users.name)"
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
            <!-- 用户：名单里的（auth_user）数一数；没被任何规则覆盖到的用黄色另计。
                 点数字进用户管理，在那里可以逐个纳入/移出 -->
            <v-col cols="4">{{ $t('relay.users') }}</v-col>
            <v-col cols="8">
              <v-chip
                size="x-small"
                label
                class="ma-1"
                :color="r.users.length === 0 ? 'warning' : 'primary'"
                variant="tonal"
                @click="openUsers(r)"
              >
                {{ r.users.length }}
              </v-chip>
              <v-chip
                v-if="unlistedForRelay(r).length > 0"
                size="x-small"
                label
                color="warning"
                variant="outlined"
                class="ma-1"
                @click="openUsers(r)"
              >
                <v-icon start size="x-small" icon="mdi-alert" />{{ unlistedForRelay(r).length }}
                <v-tooltip activator="parent" location="top" max-width="320">
                  {{ $t('relay.unlisted') + ' ' + unlistedForRelay(r).join(', ') }}
                </v-tooltip>
              </v-chip>
              <v-chip
                v-if="r.legacy.length > 0"
                size="x-small"
                label
                color="info"
                variant="tonal"
                class="ma-1"
              >
                {{ $t('relay.wholeInbound') }}
                <v-tooltip activator="parent" location="top" max-width="320">{{ $t('relay.wholeInboundHint') }}</v-tooltip>
              </v-chip>
              <v-icon size="small" icon="mdi-account-cog" @click="openUsers(r)">
                <v-tooltip activator="parent" location="top" :text="$t('relay.manageUsers')" />
              </v-icon>
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
          <!-- 用户管理：入口入站上的客户端（增删改 + 二维码） -->
          <v-btn icon="mdi-account-multiple" @click="openUsers(r)">
            <v-icon />
            <v-tooltip activator="parent" location="top" :text="$t('relay.manageUsers')" />
          </v-btn>
          <!-- 「整条入站」模式才有：把它展开成每个用户一条规则 -->
          <v-btn v-if="r.legacy.length > 0" icon="mdi-account-convert" :loading="converting" @click="convertToUsers(r)">
            <v-icon />
            <v-tooltip activator="parent" location="top" :text="$t('relay.convertUsers')" />
          </v-btn>
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
import RelayUsers from '@/layouts/modals/RelayUsers.vue'
import QrCode from '@/layouts/modals/QrCode.vue'
import ExportLinks from '@/layouts/modals/ExportLinks.vue'
import { i18n } from '@/locales'
import { push } from 'notivue'
import { computed, ref } from 'vue'

const wizardModal = ref(false)   // 「添加中转」向导弹窗
const exportModal = ref(false)   // 「导出链接」弹窗
const delOverlay = ref<boolean[]>([]) // 每张卡独立的删除确认覆盖层
const delLoading = ref(false)
const clearConfirm = ref(false)  // 「全部删除」确认框
const clearLoading = ref(false)
const checkResults = ref<Record<string, any>>({}) // 落地测速结果，按出站 tag 索引

// 用户管理弹窗（RelayUsers.vue）：按中转逐个打开
const users = ref({ visible: false, name: '', entryTags: <string[]>[] })
const openUsers = (r: any) => {
  users.value.name = r.outbound
  users.value.entryTags = [...r.inbounds]
  users.value.visible = true
}

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

// 客户端挂在哪些入站上（tag 形式）。id -> tag 的反查每次都做一遍有点费，
// 但入站数量是个位数到十几条，不值得为它建缓存。
const inboundTagsOf = (c: any): string[] =>
  (c.inbounds || [])
    .map((id: number) => (Data().inbounds || []).find((i: any) => i.id == id)?.tag)
    .filter((t: any): t is string => !!t)

// 挂在入口入站上、却没有任何规则把它送到这个落地的客户端。
// 按用户分流之后这些用户的流量不会走中转（落到默认出站），卡片必须让人看见，
// 否则「我在入站页加了个用户怎么不走中转」这种问题无从查起。
// 被「整条入站」规则覆盖到的不算 —— 那种规则不限用户，走得到。
const unlistedForRelay = (r: any): string[] =>
  clientsForRelay(r)
    .filter((c: any) => !r.users.includes(c.name))
    .filter((c: any) => !inboundTagsOf(c).some((t: string) => r.legacy.includes(t)))
    .map((c: any) => c.name)
const showRelayQr = (r: any) => {
  const cls = clientsForRelay(r)
  if (cls.length === 0) {
    // 入口入站上还没有用户 —— 以前这里直接 return，按钮点了毫无反应。
    // 现在说明原因并把用户管理打开，让操作员当场建一个。
    push.warning({ message: i18n.global.t('relay.noUsers') })
    openUsers(r)
    return
  }
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
//
// 按用户分流时同一个落地出站对应多条规则（每用户一条），所以这里按 outbound
// 聚合：一张卡 = 一个落地出站 + 它的全部入口入站 + 它的用户名单。
// ------------------------------------------------------------------------
const relays = computed((): any[] => {
  const config: any = Data().config || {}
  const rules: any[] = config.route?.rules || []
  const obs: any[] = Data().outbounds || []
  const byTag = new Map<string, any>()
  const order: string[] = []
  rules.forEach((rule: any) => {
    if (!(rule && rule.action === 'route' && rule.outbound && rule.inbound)) return
    const ob = obs.find((o: any) => o.tag === rule.outbound)
    if (!ob) return
    let g = byTag.get(rule.outbound)
    if (!g) {
      g = { outbound: ob.tag, type: ob.type, server: ob.server ?? '-', inbounds: <string[]>[], users: <string[]>[], legacy: <string[]>[] }
      byTag.set(rule.outbound, g)
      order.push(rule.outbound)
    }
    // 规则里的 inbound 可能是字符串或数组，统一成数组
    const inb: string[] = Array.isArray(rule.inbound) ? rule.inbound : [rule.inbound]
    inb.forEach((t: string) => { if (!g.inbounds.includes(t)) g.inbounds.push(t) })
    if (Array.isArray(rule.auth_user) && rule.auth_user.length > 0) {
      // 按用户：这条规则只放这些用户过去
      rule.auth_user.forEach((u: string) => { if (!g.users.includes(u)) g.users.push(u) })
    } else {
      // 整条入站：没有 auth_user，这个入站的流量不分用户全走
      inb.forEach((t: string) => { if (!g.legacy.includes(t)) g.legacy.push(t) })
    }
  })
  return order.map((t: string) => byTag.get(t))
})

// ---------------------------------------------------------------------------
// 把「整条入站」的规则展开成「每个用户一条」。
// 展开 = 给该落地入口入站上的每个现有客户端各生成一条 auth_user 规则，
// 插到原来那条规则的位置上，再把原来的整条入站规则删掉。一次保存。
//
// 展开之后新加的用户必须在中转卡片上纳入，否则不会走这个落地 —— 这是
// 按用户分流的代价，卡片上的黄色数字就是干这个提醒的。
// 没有客户端可展开时直接拒绝：展开成零条规则等于把这个中转拆没了。
// ---------------------------------------------------------------------------
const converting = ref(false)
const convertToUsers = async (r: any) => {
  const cls = clientsForRelay(r)
  if (cls.length === 0) {
    push.warning({ message: i18n.global.t('relay.convertNoUser') })
    return
  }
  converting.value = true
  const config = JSON.parse(JSON.stringify(Data().config || {}))
  const rules: any[] = config.route?.rules || []
  const isRelayRule = (rule: any) => rule && rule.action === 'route' && rule.outbound === r.outbound
  const fresh: any[] = cls.map((c: any) => ({
    // inbound 写本中转的全部入口入站：用户只能在自己绑定的入站上认证，
    // 多写的那些永远匹配不上，但以后把用户挂到另一个入口入站时规则不用跟着改
    inbound: [...r.inbounds],
    auth_user: [c.name],
    action: 'route',
    outbound: r.outbound,
  }))
  const at = rules.findIndex(isRelayRule)
  const kept = rules.filter((rule: any) => !isRelayRule(rule))
  kept.splice(at < 0 ? kept.length : at, 0, ...fresh)
  config.route.rules = kept
  await Data().save('config', 'set', config)
  converting.value = false
  push.success({ title: i18n.global.t('success'), message: i18n.global.t('relay.converted') + ' (' + fresh.length + ')' })
}

// 用户管理弹窗按出站 tag 打开；RelayUsers 里做完「转为按用户」后发 convert
// 事件回来，由这里统一执行，避免两份一样的规则改写逻辑。
const convertByName = (tag: string) => {
  const r = relays.value.find((x: any) => x.outbound === tag)
  if (r) convertToUsers(r)
}

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
