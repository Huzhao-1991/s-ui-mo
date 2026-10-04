<template>
  <v-dialog
    :model-value="visible"
    transition="dialog-bottom-transition"
    width="560"
    @update:model-value="(v: boolean) => { if (!v) $emit('close') }"
  >
    <v-card
      class="rounded-lg"
      :loading="loading"
    >
      <v-card-title>
        <v-row>
          <v-col>{{ $t('actions.' + (form.id ? 'edit' : 'add')) + ' ' + $t('objects.server') }}</v-col>
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
        <v-text-field
          v-model="form.name"
          :label="$t('server.name')"
          hide-details
          class="mb-4"
        />
        <v-text-field
          v-model="form.url"
          :label="$t('server.url')"
          :hint="$t('server.urlHint')"
          persistent-hint
          placeholder="http://1.2.3.4:2095/app/"
          class="mb-4"
        />
        <v-text-field
          v-model="form.token"
          :label="$t('server.token')"
          :hint="$t('server.tokenHint')"
          persistent-hint
          :type="showPass ? 'text' : 'password'"
          :append-inner-icon="showPass ? 'mdi-eye-off' : 'mdi-eye'"
          class="mb-4"
          @click:append-inner="showPass = !showPass"
        />
        <v-text-field
          v-model="form.remark"
          :label="$t('server.remark')"
          hide-details
        />
      </v-card-text>
      <v-divider />
      <v-card-actions>
        <v-spacer />
        <v-btn
          color="primary"
          variant="outlined"
          @click="$emit('close')"
        >
          {{ $t('actions.close') }}
        </v-btn>
        <v-btn
          color="primary"
          variant="tonal"
          :loading="loading"
          @click="save"
        >
          {{ $t('actions.save') }}
        </v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script lang="ts" setup>
import Data from '@/store/modules/data'
import { i18n } from '@/locales'
import { push } from 'notivue'
import { ref, watch } from 'vue'
import type { Server } from '@/types/servers'

const props = defineProps<{
  visible: boolean
  server: Server | null
}>()

const emit = defineEmits<{ close: [] }>()

const loading = ref(false)
const showPass = ref(false)
const form = ref<Server>({ id: 0, name: '', url: '', token: '', remark: '' })

watch(() => props.visible, (v: boolean) => {
  if (!v) return
  const s = props.server
  form.value = s
    ? { id: s.id, name: s.name, url: s.url, token: s.token ?? '', remark: s.remark ?? '' }
    : { id: 0, name: '', url: '', token: '', remark: '' }
  showPass.value = false
  loading.value = false
})

// A bare host is far easier to type than a full origin, and the backend
// normalises either form, so only the scheme is filled in here.
function normalizeUrl(u: string): string {
  u = (u || '').trim()
  if (u && !/^https?:\/\//i.test(u)) u = 'http://' + u
  return u
}

async function save() {
  const name = (form.value.name || '').trim()
  const url = normalizeUrl(form.value.url)
  if (!name || !url) {
    push.error({
      message: i18n.global.t('error.invalidData') + ': ' + i18n.global.t('server.url'),
    })
    return
  }
  loading.value = true
  const payload: Server = {
    name,
    url,
    token: (form.value.token || '').trim(),
    remark: (form.value.remark || '').trim(),
  }
  if (form.value.id) payload.id = form.value.id
  const success = await Data().save('servers', form.value.id ? 'edit' : 'new', payload)
  loading.value = false
  if (success) emit('close')
}
</script>
