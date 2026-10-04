<template>
  <ServerModal
    :visible="editModal.visible"
    :server="editModal.server"
    @close="editModal.visible = false"
  />
  <v-alert
    v-if="currentServer"
    type="warning"
    variant="tonal"
    density="compact"
    class="mb-4"
  >
    <v-row
      align="center"
      class="ma-0"
    >
      <v-col class="pa-0">
        {{ $t('server.managingHint', { name: managedName }) }}
      </v-col>
      <v-col cols="auto">
        <v-btn
          color="warning"
          variant="outlined"
          size="small"
          @click="backToLocal"
        >
          {{ $t('server.backToLocal') }}
        </v-btn>
      </v-col>
    </v-row>
  </v-alert>
  <v-row justify="center">
    <v-col cols="auto">
      <v-btn
        color="primary"
        prepend-icon="mdi-server-plus"
        @click="showEdit(null)"
      >
        {{ $t('server.add') }}
      </v-btn>
    </v-col>
    <v-col cols="auto">
      <v-btn
        variant="outlined"
        prepend-icon="mdi-lan-pending"
        :disabled="servers.length === 0"
        @click="testAll"
      >
        {{ $t('actions.testAll') }}
      </v-btn>
    </v-col>
  </v-row>
  <v-row v-if="servers.length === 0">
    <v-col
      cols="12"
      class="text-center text-medium-emphasis"
    >
      {{ $t('server.empty') }}
    </v-col>
  </v-row>
  <v-row>
    <v-col
      v-for="(item, index) in servers"
      :key="item.id"
      cols="12"
      sm="6"
      md="4"
      lg="3"
    >
      <v-card
        rounded="xl"
        elevation="5"
        :title="item.name"
        :color="currentServer === String(item.id) ? 'primary' : undefined"
      >
        <v-card-subtitle class="text-wrap">
          {{ item.url }}
        </v-card-subtitle>
        <v-card-text>
          <div class="mb-2">
            <v-chip
              v-if="statusOf(item).state === 'testing'"
              size="small"
              color="grey"
              variant="tonal"
            >
              <v-progress-circular
                size="12"
                width="2"
                indeterminate
                class="mr-1"
              />
              {{ $t('server.testing') }}
            </v-chip>
            <v-chip
              v-else-if="statusOf(item).state === 'online'"
              size="small"
              color="success"
              variant="tonal"
              prepend-icon="mdi-check-circle"
            >
              {{ statusOf(item).latency }} ms
            </v-chip>
            <v-chip
              v-else-if="statusOf(item).state === 'offline'"
              size="small"
              color="error"
              variant="tonal"
              prepend-icon="mdi-alert-circle"
            >
              {{ $t('server.offline') }}<template v-if="statusOf(item).error">: {{ statusOf(item).error }}</template>
            </v-chip>
            <v-chip
              v-else
              size="small"
              color="grey"
              variant="tonal"
            >
              {{ $t('server.untested') }}
            </v-chip>
          </div>
          <div
            v-if="currentServer === String(item.id)"
            class="font-weight-bold"
          >
            ● {{ $t('server.managing') }}
          </div>
          <div
            v-if="item.remark"
            class="text-medium-emphasis"
          >
            {{ item.remark }}
          </div>
        </v-card-text>
        <v-divider />
        <v-card-actions>
          <v-btn
            icon="mdi-lan-pending"
            @click.stop="testServer(item)"
          >
            <v-icon />
            <v-tooltip
              activator="parent"
              location="top"
              :text="$t('server.test')"
            />
          </v-btn>
          <v-btn
            icon="mdi-cog"
            color="primary"
            @click.stop="manage(item)"
          >
            <v-icon />
            <v-tooltip
              activator="parent"
              location="top"
              :text="$t('server.manage')"
            />
          </v-btn>
          <v-btn
            icon="mdi-file-edit"
            @click.stop="showEdit(item)"
          >
            <v-icon />
            <v-tooltip
              activator="parent"
              location="top"
              :text="$t('actions.edit')"
            />
          </v-btn>
          <v-btn
            icon="mdi-file-remove"
            color="warning"
            @click.stop="delOverlay[index] = true"
          >
            <v-icon />
            <v-tooltip
              activator="parent"
              location="top"
              :text="$t('actions.del')"
            />
          </v-btn>
          <v-overlay
            v-model="delOverlay[index]"
            contained
            class="align-center justify-center"
          >
            <v-card
              :title="$t('actions.del')"
              rounded="lg"
            >
              <v-divider />
              <v-card-text>
                {{ $t('confirm') }}
                <!-- Opt-in, off by default: this talks to the remote and
                     deletes every inbound on it. -->
                <v-checkbox
                  v-model="wipeNodes[index]"
                  :label="$t('server.wipeNodes')"
                  color="error"
                  density="compact"
                  hide-details
                  class="mt-2"
                />
              </v-card-text>
              <v-card-actions>
                <v-btn
                  color="error"
                  variant="outlined"
                  @click.stop="delServer(item, index)"
                >
                  {{ $t('yes') }}
                </v-btn>
                <v-btn
                  color="success"
                  variant="outlined"
                  @click.stop="delOverlay[index] = false"
                >
                  {{ $t('no') }}
                </v-btn>
              </v-card-actions>
            </v-card>
          </v-overlay>
        </v-card-actions>
      </v-card>
    </v-col>
  </v-row>
</template>

<script lang="ts" setup>
import Data from '@/store/modules/data'
import HttpUtils from '@/plugins/httputil'
import api from '@/plugins/api'
import ServerModal from '@/layouts/modals/Server.vue'
import { computed, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import type { Server } from '@/types/servers'

const router = useRouter()

const servers = computed((): Server[] => Data().servers ?? [])
const currentServer = computed((): string => Data().currentServer)
const managedName = computed((): string => {
  const hit = servers.value.find(s => String(s.id) === currentServer.value)
  return hit?.name ?? currentServer.value
})

const editModal = ref<{ visible: boolean, server: Server | null }>({ visible: false, server: null })
const delOverlay = ref<boolean[]>([])
const wipeNodes = ref<boolean[]>([])

type ServerStatus = { state: 'idle' | 'testing' | 'online' | 'offline', latency?: number, error?: string }
const statusMap = ref<Record<string, ServerStatus>>({})
const statusOf = (item: Server): ServerStatus => statusMap.value[String(item.id)] ?? { state: 'idle' }

// Probed through the backend, which calls the remote's APIv2 status endpoint
// and times the round trip. The browser cannot do it itself: the token would
// have to be handed to the page and the remote would have to answer CORS.
async function testServer(item: Server) {
  const key = String(item.id)
  statusMap.value = { ...statusMap.value, [key]: { state: 'testing' } }
  const r = await HttpUtils.get<{ online: boolean, latency?: number, error?: string }>('api/testServer', { id: item.id })
  const o = r.obj ?? { online: false }
  statusMap.value = {
    ...statusMap.value,
    [key]: o.online
      ? { state: 'online', latency: o.latency }
      : { state: 'offline', error: o.error },
  }
}

function testAll() {
  servers.value.forEach(testServer)
}

// Probe on arrival and again whenever the list changes (add, edit, delete).
watch(servers, () => testAll(), { immediate: true })

function showEdit(server: Server | null) {
  editModal.value.server = server
  editModal.value.visible = true
}

// Hand the whole UI over to this server and land on its inbounds.
async function manage(item: Server) {
  await Data().switchServer(String(item.id))
  router.push('/inbounds')
}

async function backToLocal() {
  await Data().switchServer('')
  router.push('/servers')
}

// Delete every inbound on a remote, talking to it through the proxy header
// directly so the local view is not overwritten with the remote's data.
async function wipeRemoteNodes(serverId: string) {
  // The header rides on both hops, and it is passed explicitly rather than
  // relying on the interceptor: the server being wiped need not be the one
  // currently selected, and the interceptor only fills the header in when the
  // caller left it blank. The loop variable used to be named `id` as well and
  // shadowed this one, so every delete was addressed to an inbound number
  // instead of the server.
  const headers = { 'X-Remote-Server': serverId }
  const resp = await api.get('api/inbounds', { headers })
  const inbounds: unknown[] = resp.data?.obj?.inbounds ?? []
  for (const raw of inbounds) {
    const inboundId = (raw as { id?: number }).id
    if (inboundId == undefined) continue
    await api.post('api/save',
      { object: 'inbounds', action: 'del', data: JSON.stringify(inboundId) },
      { headers })
  }
}

async function delServer(item: Server, index: number) {
  if (wipeNodes.value[index] && item.id != undefined) {
    // An unreachable remote cannot be cleaned; the entry still goes, so the
    // operator is never stuck with a broken row they cannot remove.
    try {
      await wipeRemoteNodes(String(item.id))
    } catch {
      // ignored on purpose — see above
    }
  }
  const success = await Data().save('servers', 'del', item.id)
  if (!success) return
  // Removing the server we were managing has to release the selection too, or
  // every later request keeps being proxied to something that no longer exists.
  if (String(item.id) === currentServer.value) {
    await Data().switchServer('')
  }
  delOverlay.value[index] = false
  wipeNodes.value[index] = false
}
</script>
