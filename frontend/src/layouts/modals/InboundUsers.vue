<template>
  <!-- ======================================================================
    入站用户管理（InboundUsers）
    --------------------------------------------------------------------
    从入站管理页的某张卡片打开，列出挂在这个入站上的全部客户端，格式与
    「用户管理」页一致（v-data-table + 勾选框），可以逐行编辑 / 出二维码 /
    删除，也可以勾选多行批量删除。

    列表来源和路由规则无关，只看绑定关系：clients 里 inbounds 含本入站 id 的
    那些。后端在保存 clients 时会把凭据写回它绑定的入站（UpdateInboundsUsers），
    所以这张表既是「谁能从这个入站连进来」，也是 sing-box 配置里 users 的真相。

    删除 = 彻底删掉这个客户端记录（api/save object=clients action=del），
    它在所有入站上的绑定一起消失 —— 不是「只从这个入站摘掉」。要保留账号
    只是换个入口，请去「用户管理」页改它的入站绑定。
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
  <!-- 单个删除：确认框 -->
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
  <!-- 批量删除：确认框，列出全部待删名字 -->
  <v-dialog
    v-model="delBulk.visible"
    width="auto"
  >
    <v-card
      class="rounded-lg"
      :title="$t('actions.del')"
    >
      <v-divider />
      <v-card-text>
        <p>{{ $t('client.delSelectedConfirm', { n: delBulkNames.length }) }}</p>
        <p
          class="mt-2"
          style="font-size: 0.85rem; opacity: 0.8; word-break: break-all;"
        >
          {{ delBulkNames.join(', ') }}
        </p>
      </v-card-text>
      <v-card-actions>
        <v-spacer />
        <v-btn
          color="success"
          variant="outlined"
          @click="delBulk.visible = false"
        >
          {{ $t('no') }}
        </v-btn>
        <v-btn
          color="error"
          variant="tonal"
          :loading="delBulk.loading"
          @click="delBulkUsers"
        >
          {{ $t('yes') }}
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
  <v-dialog
    :model-value="visible"
    transition="dialog-bottom-transition"
    width="1000"
    @update:model-value="onDialogToggle"
  >
    <v-card class="rounded-lg">
      <v-card-title>
        <v-row align="center">
          <v-col>{{ $t('in.users') }}<span
            v-if="tag"
            class="text-medium-emphasis"
          > · {{ tag }}</span></v-col>
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
        {{ $t('in.usersHint') }}
      </v-card-subtitle>
      <v-card-text style="overflow-y: auto; max-height: 60vh; padding-top: 0;">
        <v-row v-if="users.length === 0">
          <v-col
            cols="12"
            style="text-align: center; opacity: 0.6; margin-top: 20px;"
          >
            {{ $t('in.noUsers') }}
          </v-col>
        </v-row>
        <v-data-table
          v-else
          v-model="selected"
          show-select
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
          <!-- 该用户挂的所有入站 tag；属于本入站的用 primary 标出来 -->
          <template #item.inbounds="{ item }">
            <v-chip
              v-for="t in tagsOf(item)"
              :key="t"
              size="x-small"
              label
              class="ma-1"
              :color="t == tag ? 'primary' : ''"
              :variant="t == tag ? 'tonal' : 'outlined'"
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
          <!-- 勾了人就出现批量删除条 -->
          <template
            v-if="selected.length > 0"
            #bottom
          >
            <v-row
              justify="center"
              align="center"
              class="py-2"
            >
              <v-col cols="auto">
                <v-btn
                  color="error"
                  variant="tonal"
                  prepend-icon="mdi-delete"
                  @click="delBulk.visible = true"
                >
                  {{ $t('client.delSelected', { n: selected.length }) }}
                </v-btn>
              </v-col>
              <v-col cols="auto">
                <v-btn
                  variant="text"
                  @click="selected = []"
                >
                  {{ $t('client.clearSelection') }}
                </v-btn>
              </v-col>
            </v-row>
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
// 入站用户管理
// 列表 = Data().clients 里 inbounds 含本入站 id 的客户端。
// 增删改全部复用全局那套：ClientModal（api/save object=clients）+ QrCode。
// ---------------------------------------------------------------------------
import Data from '@/store/modules/data'
import ClientModal from '@/layouts/modals/Client.vue'
import QrCode from '@/layouts/modals/QrCode.vue'
import { Client } from '@/types/clients'
import { computed, ref, watch } from 'vue'
import { HumanReadable } from '@/plugins/utils'
import { i18n } from '@/locales'
import HttpUtils from '@/plugins/httputil'
import { push } from 'notivue'

const props = defineProps<{
  visible: boolean
  // 本入站的 id（客户端的 inbounds 里存的是 id）
  inboundId: number
  // 本入站 tag，只用于标题与高亮
  tag: string
}>()

const emit = defineEmits<{ close: [] }>()

// v-dialog 关闭（点遮罩 / Esc）时也要通知父组件，否则父组件的 visible 还是 true
const onDialogToggle = (v: boolean) => {
  if (!v) emit('close')
}

type ClientRow = Client & { id: number }

// 挂在本入站上的客户端
const users = computed((): ClientRow[] =>
  (Data().clients || []).filter((c: any) =>
    Array.isArray(c.inbounds) && c.inbounds.includes(props.inboundId)
  ) as ClientRow[]
)

// 勾选：表格 item-value 是 name，存用户名再映射回 id
const selected = ref<string[]>([])

const delBulkNames = computed((): string[] =>
  users.value.filter(c => selected.value.includes(c.name)).map(c => c.name)
)

// 每次打开都清空，避免上一个入站留下的勾选被带到这一批里
watch(() => props.visible, v => { if (v) selected.value = [] })

const groups = computed((): string[] =>
  Array.from(new Set((Data().clients || []).map((c: any) => c.group)))
)

// 可绑定的入站（带 users 字段的那些），与全局用户页一致
const inboundTags = computed((): { title: string, value: number }[] =>
  (Data().inbounds || [])
    .filter((i: any) => i.tag != '' && (i as { users?: unknown }).users)
    .map((i: any) => ({ title: i.tag, value: i.id }))
)

// 从这里新建用户时把本入站预先勾上
const presetInbounds = computed((): number[] =>
  inboundTags.value.some(t => t.value == props.inboundId) ? [props.inboundId] : []
)

const isOnline = (name: string) => Data().onlines?.user?.includes(name) ?? false

const tagsOf = (item: ClientRow): string[] =>
  (item.inbounds || [])
    .map((id: number) => (Data().inbounds || []).find((i: any) => i.id == id)?.tag)
    .filter((t: any): t is string => !!t)

const headers = [
  { title: i18n.global.t('client.name'), key: 'name' },
  { title: i18n.global.t('enable'), key: 'enable', width: 80 },
  { title: i18n.global.t('client.group'), key: 'group' },
  { title: i18n.global.t('pages.inbounds'), key: 'inbounds', sortable: false },
  { title: i18n.global.t('stats.volume'), key: 'volume' },
  { title: i18n.global.t('date.expiry'), key: 'expiry' },
  { title: i18n.global.t('online'), key: 'online' },
  { title: i18n.global.t('actions.action'), key: 'actions', sortable: false },
]

// ---- 新增 / 编辑：复用全局用户弹窗 --------------------------------------
const editor = ref({ visible: false, id: 0 })

const addUser = () => {
  editor.value.id = 0
  editor.value.visible = true
}

const editUser = (id: number) => {
  editor.value.id = id
  editor.value.visible = true
}

const closeEditor = () => {
  editor.value.visible = false
}

// ---- 二维码 ------------------------------------------------------------
const qrcode = ref({ visible: false, id: 0 })

const showQrCode = (id: number) => {
  qrcode.value.id = id
  qrcode.value.visible = true
}

// ---- 启用开关：先取全量再改，避免把关联字段写丢 --------------------------
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

// 直接发请求而不走 Data().save：后者每成功一次就弹一条通知，批量删 N 个会刷屏
const removeClients = async (rows: ClientRow[]): Promise<string[]> => {
  const failed = <string[]>[]
  for (const c of rows) {
    const msg = await HttpUtils.post('api/save', {
      object: 'clients',
      action: 'del',
      data: JSON.stringify(c.id),
    })
    if (!msg.success) failed.push(c.name)
  }
  return failed
}

const notifyResult = (total: number, failed: string[]) => {
  if (failed.length == 0) {
    push.success({
      title: i18n.global.t('success'),
      duration: 5000,
      message: i18n.global.t('client.delSelectedDone', { n: total }),
    })
  } else {
    push.error({
      duration: 8000,
      message: i18n.global.t('client.delSelectedFailed', {
        ok: total - failed.length,
        err: failed.length,
        names: failed.join(', '),
      }),
    })
  }
}

// ---- 单个删除 ----------------------------------------------------------
const del = ref({ visible: false, loading: false, id: 0, name: '' })

const askDelUser = (item: ClientRow) => {
  del.value.id = item.id
  del.value.name = item.name
  del.value.visible = true
}

const delUser = async () => {
  del.value.loading = true
  const row = users.value.find((c: ClientRow) => c.id === del.value.id)
  const failed = await removeClients(row ? [row] : [])
  del.value.loading = false
  del.value.visible = false
  notifyResult(row ? 1 : 0, failed)
}

// ---- 批量删除：软失败，某个删不掉不中断后续 ----------------------------
const delBulk = ref({ visible: false, loading: false })

const delBulkUsers = async () => {
  delBulk.value.loading = true
  const rows = users.value.filter(c => selected.value.includes(c.name))
  const failed = await removeClients(rows)
  delBulk.value.loading = false
  delBulk.value.visible = false
  selected.value = []
  notifyResult(rows.length, failed)
}
</script>
