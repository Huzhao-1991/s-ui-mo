<template>
  <!-- ======================================================================
    入站管理（Inbounds）
    --------------------------------------------------------------------
    从卡片网格改成和用户管理页一样的表格：一行一个入站，带勾选框，
    勾上之后可以整批删除。

    为什么换掉卡片：卡片一张占 1/6 屏宽，入站一多就要翻好几屏才能比对，
    而且卡片里每个字段都要重复写一遍标签（"地址 / 端口 / TLS / 客户端"），
    信息密度低。表格一列一个字段，能排序，勾选也是表格自带的交互。

    卡片上的四个操作（编辑 / 删除 / 克隆 / 流量统计）原样挪到操作列，
    图标和 tooltip 都没变。
    ====================================================================== -->
  <InboundVue
    :id="modal.id"
    v-model="modal.visible"
    :visible="modal.visible"
    :in-tags="inTags"
    :tls-configs="tlsConfigs"
    @close="closeModal"
  />
  <Stats
    v-model="stats.visible"
    :visible="stats.visible"
    :resource="stats.resource"
    :tag="stats.tag"
    @close="closeStats"
  />
  <Sessions
    v-model="sessions.visible"
    :visible="sessions.visible"
    resource="inbound"
    :tag="sessions.tag"
    @close="closeSessions"
  />
  <InboundUsers
    v-model="usersModal.visible"
    :visible="usersModal.visible"
    :inbound-id="usersModal.id"
    :tag="usersModal.tag"
    @close="closeUsers"
  />
  <!-- 单个入站删除：确认框 -->
  <v-dialog
    v-model="del.visible"
    width="380"
  >
    <v-card
      class="rounded-lg"
      :title="$t('actions.del')"
    >
      <v-divider />
      <v-card-text>{{ $t('confirm') }} — {{ del.tag }}</v-card-text>
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
          @click="delInbound"
        >
          {{ $t('yes') }}
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
  <!-- 批量删除入站：确认框，列出全部待删 tag -->
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
        <p>{{ $t('in.delSelectedConfirm', { n: selected.length }) }}</p>
        <p
          class="mt-2"
          style="font-size: 0.85rem; opacity: 0.8; word-break: break-all;"
        >
          {{ selected.join(', ') }}
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
          @click="delBulkInbounds"
        >
          {{ $t('yes') }}
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
  <v-row
    justify="center"
    align="center"
  >
    <v-col cols="auto">
      <v-btn
        color="primary"
        @click="showModal(0)"
      >
        {{ $t('actions.add') }}
      </v-btn>
    </v-col>
    <v-col
      v-if="selected.length > 0"
      cols="auto"
    >
      <v-btn
        color="error"
        variant="tonal"
        prepend-icon="mdi-delete"
        @click="delBulk.visible = true"
      >
        {{ $t('in.delSelected', { n: selected.length }) }}
      </v-btn>
    </v-col>
    <v-col
      v-if="selected.length > 0"
      cols="auto"
    >
      <v-btn
        variant="text"
        @click="selected = []"
      >
        {{ $t('client.clearSelection') }}
      </v-btn>
    </v-col>
  </v-row>
  <v-row>
    <v-col cols="12">
      <v-data-table
        v-model="selected"
        show-select
        :headers="headers"
        :items="<any[]>inbounds"
        :items-per-page="itemPerPage"
        :hide-default-footer="inbounds.length<=10"
        hide-no-data
        fixed-header
        item-value="tag"
        :mobile="smAndDown"
        mobile-breakpoint="sm"
        width="100%"
        class="elevation-3 rounded"
        @update:items-per-page="setItemPerPage($event)"
      >
        <template #item.tls_id="{ item }">
          {{ item.tls_id > 0 ? $t('enable') : $t('disable') }}
        </template>
        <!-- 挂在这个入站上的客户端：数字，悬停看全部用户名 -->
        <template #item.users="{ item }">
          <span>
            <v-tooltip
              v-if="item.users && item.users.length > 0"
              activator="parent"
              dir="ltr"
              location="start"
            >
              <span
                v-for="u in item.users"
                :key="u"
              >{{ u }}<br></span>
            </v-tooltip>
            {{ item.users ? item.users.length : '-' }}
          </span>
        </template>
        <template #item.online="{ item }">
          <div class="text-start">
            <v-chip
              v-if="onlines.includes(item.tag)"
              density="comfortable"
              size="small"
              color="success"
              variant="flat"
              link
              @click="showSessions(item.tag)"
            >
              {{ $t('online') }}
              <v-tooltip
                activator="parent"
                location="top"
                :text="$t('sessions.title')"
              />
            </v-chip>
            <template v-else>
              -
            </template>
          </div>
        </template>
        <template #item.actions="{ item }">
          <v-icon
            class="me-2"
            @click="showModal(item.id)"
          >
            mdi-pencil
          </v-icon>
          <v-icon
            class="me-2"
            color="primary"
            @click="showUsers(item.id, item.tag)"
          >
            mdi-account-multiple
          </v-icon>
          <v-icon
            class="me-2"
            color="error"
            @click="askDelInbound(item.id, item.tag)"
          >
            mdi-delete
          </v-icon>
          <v-icon
            class="me-2"
            @click="clone(item.id)"
          >
            mdi-content-duplicate
          </v-icon>
          <v-icon
            v-if="Data().enableTraffic"
            icon="mdi-chart-line"
            @click="showStats(item.tag)"
          >
            <v-tooltip
              activator="parent"
              location="top"
              :text="$t('stats.graphTitle')"
            />
          </v-icon>
        </template>
      </v-data-table>
    </v-col>
  </v-row>
</template>

<script lang="ts" setup>
import Data from '@/store/modules/data'
import InboundVue from '@/layouts/modals/Inbound.vue'
import InboundUsers from '@/layouts/modals/InboundUsers.vue'
import Stats from '@/layouts/modals/Stats.vue'
import Sessions from '@/layouts/modals/Sessions.vue'
import { computed, ref } from 'vue'
import { createInbound, Inbound } from '@/types/inbounds'
import { tls } from '@/types/tls'
import RandomUtil from '@/plugins/randomUtil'
import HttpUtils from '@/plugins/httputil'
import { push } from 'notivue'
import { i18n } from '@/locales'
import { useDisplay } from 'vuetify'

const { smAndDown } = useDisplay()

const inbounds = computed((): Inbound[] => {
  return <Inbound[]> Data().inbounds
})

const tlsConfigs = computed((): tls[] => {
  return Data().tlsConfigs
})

const inTags = computed((): string[] => {
  return [...(inbounds.value?.map(i => i.tag) ?? []), ...(Data().endpoints?.filter(e => e.listen_port > 0).map(e => e.tag) ?? [])]
})

const onlines = computed(() => {
  return Data().onlines.inbound?? []
})

const modal = ref({
  visible: false,
  id: 0,
})

const showModal = (id: number) => {
  modal.value.id = id
  modal.value.visible = true
}
const closeModal = () => {
  modal.value.visible = false
}

// 勾选：item-value 是 tag，所以存的是入站 tag（后端删除入站也按 tag 定位）
const selected = ref<string[]>([])

// ---- 单个删除 ----------------------------------------------------------
const del = ref({ visible: false, loading: false, id: 0, tag: '' })

const askDelInbound = (id: number, tag: string) => {
  del.value.id = id
  del.value.tag = tag
  del.value.visible = true
}

const delInbound = async () => {
  del.value.loading = true
  const ok = await Data().save("inbounds", "del", del.value.tag)
  del.value.loading = false
  if (ok) del.value.visible = false
}

// ---- 批量删除入站 ------------------------------------------------------
// 后端 api/save 的 inbounds/del 一次只收一个 tag，所以逐条发。
// 直接走 HttpUtils 而不是 Data().save：后者每成功一次就 push 一条通知，
// 删 20 个入站会刷 20 条。这里删完统一弹一条汇总。
const delBulk = ref({ visible: false, loading: false })

const delBulkInbounds = async () => {
  delBulk.value.loading = true
  const tags = inbounds.value
    .filter(i => selected.value.includes(i.tag))
    .map(i => i.tag)
  const failed = <string[]>[]
  for (const t of tags) {
    const msg = await HttpUtils.post('api/save', {
      object: 'inbounds',
      action: 'del',
      data: JSON.stringify(t),
    })
    if (!msg.success) failed.push(t)
  }
  delBulk.value.loading = false
  delBulk.value.visible = false
  selected.value = []
  if (failed.length == 0) {
    push.success({
      title: i18n.global.t('success'),
      duration: 5000,
      message: i18n.global.t('in.delSelectedDone', { n: tags.length }),
    })
  } else {
    push.error({
      duration: 8000,
      message: i18n.global.t('in.delSelectedFailed', {
        ok: tags.length - failed.length,
        err: failed.length,
        names: failed.join(', '),
      }),
    })
  }
}

let cloneLoading = ref(false)

const clone = async (id: number) => {
  cloneLoading.value = true
  const inboundArray = await Data().loadInbounds([id])
  const inbound = inboundArray[0]
  let newTag = inbound.type + "-" + RandomUtil.randomSeq(3)
  const newInbound = createInbound(inbound.type, { ...inbound,
    id: 0,
    tag: newTag,
    listen_port: RandomUtil.randomIntRange(10000, 60000),
  })
  await Data().save("inbounds", "new", newInbound)
  cloneLoading.value = false
}

const stats = ref({
  visible: false,
  resource: "inbound",
  tag: "",
})

const showStats = (tag: string) => {
  stats.value.tag = tag
  stats.value.visible = true
}
const closeStats = () => {
  stats.value.visible = false
}

const sessions = ref({
  visible: false,
  tag: "",
})

const showSessions = (tag: string) => {
  sessions.value.tag = tag
  sessions.value.visible = true
}
const closeSessions = () => {
  sessions.value.visible = false
}

// ---- 某入站的用户管理弹窗 ----------------------------------------------
const usersModal = ref({ visible: false, id: 0, tag: '' })

const showUsers = (id: number, tag: string) => {
  usersModal.value.id = id
  usersModal.value.tag = tag
  usersModal.value.visible = true
}

const closeUsers = () => {
  usersModal.value.visible = false
}

const itemPerPage = ref(localStorage.getItem('items-per-page') || '10')

const setItemPerPage = (items: number) => {
  itemPerPage.value = items.toString()
  localStorage.setItem('items-per-page', items.toString())
}

const headers = [
  { title: i18n.global.t('objects.tag'), key: 'tag' },
  { title: i18n.global.t('type'), key: 'type' },
  { title: i18n.global.t('in.addr'), key: 'listen' },
  { title: i18n.global.t('in.port'), key: 'listen_port', width: 10 },
  { title: i18n.global.t('objects.tls'), key: 'tls_id' },
  { title: i18n.global.t('pages.clients'), key: 'users', width: 10 },
  { title: i18n.global.t('online'), key: 'online' },
  { title: i18n.global.t('actions.action'), key: 'actions', sortable: false },
]
</script>
