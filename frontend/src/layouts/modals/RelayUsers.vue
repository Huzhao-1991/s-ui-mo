<template>
  <!-- ======================================================================
    中转用户管理（RelayUsers）
    --------------------------------------------------------------------
    一个中转的「用户」有两层：
      1. 客户端 —— 绑定在入口入站上、能连进来的账号（数据在 clients 表）
      2. 名单   —— 路由规则里的 auth_user，决定谁的流量真的走这个落地
    按用户分流之后这两层不再自动重合：客户端挂在入口入站上只说明"它能连"，
    要不要让它走这个落地由名单决定。本弹窗把两层放在同一张表里：
    列出入口入站上的全部客户端，每行一个「走此中转」开关，开关直接增删
    该用户的 auth_user 规则（一次 config 保存，会触发核心重启）。

    「整条入站」模式（规则没有 auth_user，即旧版形态）下名单不生效、
    整个入站都走落地，所以开关锁定，顶部给一条说明和「转为按用户」按钮。

    增删改仍然复用全局的用户弹窗（ClientModal），不另造表单。新增时把
    入口入站预先勾上（ClientModal 的 presetInbounds），并在保存成功后
    自动把新用户写进名单 —— 从这张卡片加人，意图就是让它走这个落地。
    ====================================================================== -->
  <ClientModal
    :id="editor.id"
    v-model="editor.visible"
    :visible="editor.visible"
    :groups="groups"
    :inbound-tags="inboundTags"
    :preset-inbounds="presetInbounds"
    @close="closeEditor"
  />
  <QrCode
    :id="qrcode.id"
    v-model="qrcode.visible"
    :visible="qrcode.visible"
    @close="qrcode.visible = false"
  />
  <!-- 删除是不可逆操作，先弹确认框 -->
  <v-dialog
    v-model="del.visible"
    width="380"
  >
    <v-card
      class="rounded-lg"
      :title="$t('actions.del')"
    >
      <v-divider />
      <v-card-text>{{ $t('confirm') }} — {{ del.name }}</v-card-text>
      <v-card-actions>
        <v-spacer />
        <v-btn
          color="success"
          variant="outlined"
          @click="del.visible = false"
        >
          {{ $t('no') }}
        </v-btn>
        <v-btn
          color="error"
          variant="tonal"
          :loading="del.loading"
          @click="delUser"
        >
          {{ $t('yes') }}
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
  <v-dialog
    :model-value="visible"
    transition="dialog-bottom-transition"
    width="920"
    @update:model-value="onDialogToggle"
  >
    <v-card class="rounded-lg">
      <v-card-title>
        <v-row align="center">
          <v-col>{{ $t('relay.users') }}<span
            v-if="name"
            class="text-medium-emphasis"
          > · {{ name }}</span></v-col>
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
      <v-card-subtitle class="pt-3">
        {{ $t('relay.usersHint') }}
      </v-card-subtitle>
      <v-card-text style="overflow-y: auto; max-height: 62vh; padding-top: 0;">
        <!-- 整条入站模式：名单不生效，整个入站都走这个落地。
             给一个显式的入口把它转成按用户，否则下面的开关没法用 -->
        <v-alert
          v-if="isLegacy"
          type="info"
          density="compact"
          variant="tonal"
          class="mt-3"
        >
          <div class="d-flex align-center">
            <span>{{ $t('relay.legacyHint') }}</span>
            <v-spacer />
            <v-btn
              size="x-small"
              color="primary"
              variant="outlined"
              class="ms-2"
              @click="$emit('convert')"
            >
              {{ $t('relay.convertUsers') }}
            </v-btn>
          </div>
        </v-alert>
        <!-- 该中转的入口入站：下面列出的用户都挂在这些入站上 -->
        <v-row align="center">
          <v-col
            cols="auto"
            class="text-medium-emphasis"
          >
            {{ $t('relay.entry') }}
          </v-col>
          <v-col>
            <v-chip
              v-for="t in entryTags"
              :key="t"
              size="small"
              label
              class="ma-1"
            >
              {{ t }}
            </v-chip>
          </v-col>
        </v-row>
        <v-row v-if="users.length === 0">
          <v-col
            cols="12"
            style="text-align: center; opacity: 0.6; margin-top: 20px;"
          >
            {{ $t('relay.noUsers') }}
          </v-col>
        </v-row>
        <v-data-table
          v-else
          :headers="headers"
          :items="users"
          :items-per-page="10"
          :hide-default-footer="users.length<=10"
          hide-no-data
          fixed-header
          item-value="name"
          class="elevation-3 rounded"
        >
          <template #item.enable="{ item }">
            <v-switch
              :model-value="item.enable"
              :loading="toggling[item.id]"
              :disabled="toggling[item.id]"
              color="success"
              density="compact"
              hide-details
              @update:model-value="(val:any) => toggleEnable(item, !!val)"
            />
          </template>
          <!-- 走此中转：开关直接增/删该用户的 auth_user 路由规则。
               整条入站模式下整个入站都走，开关没有意义，锁定 -->
          <template #item.routed="{ item }">
            <v-switch
              :model-value="isRouted(item)"
              :loading="busyRule[item.name]"
              :disabled="isLegacy || !!busyRule[item.name]"
              color="success"
              density="compact"
              hide-details
              @update:model-value="(val:any) => toggleRouted(item, !!val)"
            />
          </template>
          <!-- 该用户实际挂在这几个入站上；标出属于本中转的入口入站 -->
          <template #item.inbounds="{ item }">
            <v-chip
              v-for="t in tagsOf(item)"
              :key="t"
              size="x-small"
              label
              class="ma-1"
              :color="entryTags.includes(t) ? 'primary' : ''"
              :variant="entryTags.includes(t) ? 'tonal' : 'outlined'"
            >
              {{ t }}
            </v-chip>
          </template>
          <template #item.volume="{ item }">
            <v-chip
              size="small"
              :color="item.volume==0 ? 'success' : item.volume<=(item.up + item.down)? 'error': ''"
              label
            >
              {{ HumanReadable.sizeFormat(item.up + item.down) + ' / ' + (item.volume == 0 ? $t('unlimited') : HumanReadable.sizeFormat(item.volume)) }}
            </v-chip>
          </template>
          <template #item.expiry="{ item }">
            <v-chip
              size="small"
              :color="item.expiry==0 ? 'success' : item.expiry<=Date.now()/1000? 'error': ''"
              label
            >
              {{ HumanReadable.remainedDays(item.expiry) }}
            </v-chip>
          </template>
          <template #item.online="{ item }">
            <v-chip
              v-if="isOnline(item.name)"
              density="comfortable"
              size="small"
              color="success"
              variant="flat"
            >
              {{ $t('online') }}
            </v-chip>
            <template v-else>
              -
            </template>
          </template>
          <template #item.actions="{ item }">
            <v-icon
              class="me-2"
              @click="editUser(item.id)"
            >
              mdi-pencil
            </v-icon>
            <v-icon
              class="me-2"
              @click="showQrCode(item.id)"
            >
              mdi-qrcode
            </v-icon>
            <v-icon
              color="error"
              @click="askDelUser(item)"
            >
              mdi-delete
            </v-icon>
          </template>
        </v-data-table>
      </v-card-text>
      <v-divider />
      <v-card-actions>
        <v-btn
          color="primary"
          variant="tonal"
          prepend-icon="mdi-account-plus"
          @click="addUser"
        >
          {{ $t('relay.addUser') }}
        </v-btn>
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

<script lang="ts" setup>
// ---------------------------------------------------------------------------
// 中转用户管理
// 列表来源 = Data().clients 里 inbounds 命中本中转入口入站的客户端。
// 增删改全部走全局那套：ClientModal（api/save object=clients）+ QrCode。
// ---------------------------------------------------------------------------
import Data from '@/store/modules/data'
import ClientModal from '@/layouts/modals/Client.vue'
import QrCode from '@/layouts/modals/QrCode.vue'
import { Client } from '@/types/clients'
import { computed, ref } from 'vue'
import { HumanReadable } from '@/plugins/utils'
import { i18n } from '@/locales'

const props = defineProps<{
  visible: boolean
  // 本中转的入口入站 tag 列表；用户就是挂在这些入站上的
  entryTags: string[]
  // 中转名（落地出站 tag），只用于标题
  name: string
}>()

const emit = defineEmits<{ close: [], convert: [] }>()

// v-dialog 关闭（点遮罩 / Esc）时也要通知父组件，否则父组件的 visible 还是 true
const onDialogToggle = (v: boolean) => {
  if (!v) emit('close')
}

type ClientRow = Client & { id: number }

// 入口入站对象（按 tag 反查）。入口入站可能已被删除，故这里取交集。
const entryInbounds = computed(() =>
  (Data().inbounds || []).filter((i: any) => props.entryTags.includes(i.tag))
)
const entryIds = computed(() => entryInbounds.value.map((i: any) => i.id))

// 该中转的用户 = 绑定到任一入口入站的客户端
const users = computed((): ClientRow[] =>
  (Data().clients || []).filter((c: any) =>
    Array.isArray(c.inbounds) && c.inbounds.some((id: number) => entryIds.value.includes(id))
  ) as ClientRow[]
)

// ---------------------------------------------------------------------------
// 名单层：本中转（落地出站 tag = props.name）的路由规则
// ---------------------------------------------------------------------------
// 指向本落地的全部 route 规则
const relayRules = computed((): any[] => {
  const rules: any[] = (Data().config as any)?.route?.rules || []
  return rules.filter((r: any) => r && r.action === 'route' && r.outbound === props.name)
})

// 「整条入站」模式：这些规则没有 auth_user，覆盖到的入站不分用户全走
const legacyTags = computed((): string[] => {
  const s: string[] = []
  relayRules.value.forEach((r: any) => {
    if (Array.isArray(r.auth_user) && r.auth_user.length > 0) return
    ;(Array.isArray(r.inbound) ? r.inbound : [r.inbound]).forEach((t: string) => {
      if (!s.includes(t)) s.push(t)
    })
  })
  return s
})
const isLegacy = computed(() => legacyTags.value.length > 0)

// 名单：规则里出现过的用户名
const listed = computed((): string[] => {
  const s: string[] = []
  relayRules.value.forEach((r: any) => {
    if (Array.isArray(r.auth_user)) r.auth_user.forEach((u: string) => { if (!s.includes(u)) s.push(u) })
  })
  return s
})

// 某个客户端当前是否真的走这个落地：
//   名单里有它 -> 走；或它挂的某个入站被「整条入站」规则覆盖 -> 也走
const isRouted = (item: ClientRow): boolean =>
  listed.value.includes(item.name) || tagsOf(item).some((t: string) => legacyTags.value.includes(t))

// 开关「走此中转」= 增/删该用户的 auth_user 规则。一次 config 保存，
// 会触发核心重启，所以每行有自己的 loading。
const busyRule = ref<Record<string, boolean>>({})

const toggleRouted = async (item: ClientRow, on: boolean) => {
  if (isRouted(item) === on) return
  busyRule.value = { ...busyRule.value, [item.name]: true }
  try {
    const config = JSON.parse(JSON.stringify(Data().config || {}))
    const rules: any[] = config.route?.rules || []
    if (on) {
      rules.push({
        // inbound 写本中转的全部入口入站：用户只能在自己绑定的入站上认证，
        // 多写的永远匹配不上，但以后把用户挂到另一个入口入站时规则不用跟着改
        inbound: [...props.entryTags],
        auth_user: [item.name],
        action: 'route',
        outbound: props.name,
      })
    } else {
      // 只删「只写了它一个」的规则；一条规则里写了多个用户时，把它从数组里摘掉
      for (let i = rules.length - 1; i >= 0; i--) {
        const r = rules[i]
        if (!(r && r.action === 'route' && r.outbound === props.name && Array.isArray(r.auth_user))) continue
        if (!r.auth_user.includes(item.name)) continue
        if (r.auth_user.length === 1) rules.splice(i, 1)
        else rules[i] = { ...r, auth_user: r.auth_user.filter((u: string) => u !== item.name) }
      }
    }
    config.route.rules = rules
    await Data().save('config', 'set', config)
  } finally {
    busyRule.value = { ...busyRule.value, [item.name]: false }
  }
}

// 新增用户可以绑定的入站范围：与全局用户页一致（所有带 users 的入站），
// 只是把本中转的入口入站预先勾上——比"只允许绑这几个"更灵活，
// 操作员可以把同一个用户同时挂到别的线上。
const inboundTags = computed((): { title: string, value: number }[] =>
  (Data().inbounds || [])
    .filter((i: any) => i.tag != '' && (i as { users?: unknown }).users)
    .map((i: any) => ({ title: i.tag, value: i.id }))
)

// 预勾选的入口入站：取与本中转入口 tag 对应、且确实在可选列表里的那些 id
const presetInbounds = computed(() => {
  const allowed = new Set(inboundTags.value.map(t => t.value))
  return entryIds.value.filter((id: number) => allowed.has(id))
})

const groups = computed((): string[] =>
  Array.from(new Set((Data().clients || []).map((c: any) => c.group)))
)

const isOnline = (name: string) => Data().onlines?.user?.includes(name) ?? false

// 某个用户挂的入站 tag 列表（用于在表格里看出它是不是也走别处）
const tagsOf = (item: ClientRow): string[] =>
  (item.inbounds || [])
    .map((id: number) => (Data().inbounds || []).find((i: any) => i.id == id)?.tag)
    .filter((t: any): t is string => !!t)

const headers = [
  { title: i18n.global.t('client.name'), key: 'name' },
  { title: i18n.global.t('relay.routed'), key: 'routed', width: 90, sortable: false },
  { title: i18n.global.t('enable'), key: 'enable', width: 60 },
  { title: i18n.global.t('client.group'), key: 'group' },
  { title: i18n.global.t('pages.inbounds'), key: 'inbounds', sortable: false },
  { title: i18n.global.t('stats.volume'), key: 'volume' },
  { title: i18n.global.t('date.expiry'), key: 'expiry' },
  { title: i18n.global.t('online'), key: 'online' },
  { title: i18n.global.t('actions.action'), key: 'actions', sortable: false },
]

// ---- 新增 / 编辑：复用全局用户弹窗 --------------------------------------
const editor = ref({ visible: false, id: 0 })
// 打开弹窗前记下已有用户名，关掉时好认出"刚建的那个"
const knownNames = ref<string[]>([])

const addUser = () => {
  knownNames.value = users.value.map((c: ClientRow) => c.name)
  editor.value.id = 0
  editor.value.visible = true
}

const editUser = (id: number) => {
  knownNames.value = users.value.map((c: ClientRow) => c.name)
  editor.value.id = id
  editor.value.visible = true
}

const closeEditor = async () => {
  editor.value.visible = false
  // 从这张卡片新建的用户自动纳入本中转 —— 会在这里加人，意图就是让它走这个落地。
  // Data().save 成功后 store 已同步更新（setNewData），所以关弹窗时就能看到新客户端。
  // 整条入站模式下 isRouted 本来就是 true，这里自然是空操作。
  const fresh = users.value.filter((c: ClientRow) => !knownNames.value.includes(c.name))
  for (const c of fresh) {
    if (!isRouted(c)) await toggleRouted(c, true)
  }
}

// ---- 二维码 ------------------------------------------------------------
const qrcode = ref({ visible: false, id: 0 })

const showQrCode = (id: number) => {
  qrcode.value.id = id
  qrcode.value.visible = true
}

// ---- 启用开关：与全局用户页同一套（先取全量再改，避免把关联字段写丢）----
const toggling = ref<Record<number, boolean>>({})

const toggleEnable = async (item: ClientRow, val: boolean) => {
  if (item.enable === val) return
  toggling.value = { ...toggling.value, [item.id]: true }
  const full = await Data().loadClients(item.id)
  if (full?.id) {
    full.enable = val
    await Data().save('clients', 'edit', full)
  }
  toggling.value = { ...toggling.value, [item.id]: false }
}

// ---- 删除 --------------------------------------------------------------
const del = ref({ visible: false, loading: false, id: 0, name: '' })

const askDelUser = (item: ClientRow) => {
  del.value.id = item.id
  del.value.name = item.name
  del.value.visible = true
}

const delUser = async () => {
  del.value.loading = true
  // 名单里有它的先摘掉：客户端删了之后规则里会留下一个永远匹配不上的用户名。
  // 走的是「整条入站」覆盖就不用动规则 —— 那种规则没有 auth_user，摘无可摘。
  const row = users.value.find((c: ClientRow) => c.id === del.value.id)
  if (row && listed.value.includes(row.name)) await toggleRouted(row, false)
  const ok = await Data().save('clients', 'del', del.value.id)
  del.value.loading = false
  if (ok) del.value.visible = false
}
</script>
