<template>
  <v-navigation-drawer
    v-model="showDrawer"
    :temporary="isMobile"
    :expand-on-hover="!isMobile"
    :rail="!isMobile"
    :permanent="!isMobile"
    @click="isMobile ? $emit('toggleDrawer') : null"
  >
    <v-list-item
      height="63"
      prepend-avatar="@/assets/logo.svg"
      title="S-UI"
      :subtitle="managedName"
      :class="managedName ? 'text-warning' : undefined"
    >
      <template
        v-if="isMobile"
        #append
      >
        <v-icon icon="mdi-close" />
      </template>
    </v-list-item>

    <v-divider />

    <v-list
      density="compact"
      nav
    >
      <v-list-item
        v-for="item in menu"
        :key="item.title"
        link
        :to="item.path"
        :active="router.currentRoute.value.path == item.path"
      >
        <template #prepend>
          <v-icon :icon="item.icon" />
        </template>
        <v-list-item-title>{{ $t(item.title) }}</v-list-item-title>
      </v-list-item>
    </v-list>
    <template #append>
      <v-list-item
        prepend-icon="mdi-logout"
        :title="$t('menu.logout')"
        @click="Logout"
      />
    </template>
  </v-navigation-drawer>
</template>

<script lang="ts" setup>
import { computed } from 'vue'
import router from '@/router'
import { logout } from '@/plugins/httputil'
import Data from '@/store/modules/data'

const props = defineProps<{ isMobile: boolean, displayDrawer: boolean }>()
defineEmits<{ toggleDrawer: [] }>()

const showDrawer = computed((): boolean => {
  return props.displayDrawer
})

// Name of the panel the UI is currently driving, or '' when it is driving
// itself. Shown under the logo because every page then edits that panel, and
// nothing else on screen would say so.
const managedName = computed((): string => {
  const id = Data().currentServer
  if (!id) return ''
  return Data().servers.find(s => String(s.id) === id)?.name ?? id
})

const menu = [
  { title: 'pages.home', icon: 'mdi-home',  path: '/' },
  { title: 'pages.inbounds', icon: 'mdi-cloud-download',  path: '/inbounds' },
  // 中转管理：与参考魔改版一致，紧挨在入站管理后面
  { title: 'pages.relay', icon: 'mdi-transit-connection-variant',  path: '/relay' },
  { title: 'pages.clients', icon: 'mdi-account-multiple',  path: '/clients' },
  { title: 'pages.outbounds', icon: 'mdi-cloud-upload',  path: '/outbounds' },
  { title: 'pages.endpoints', icon: 'mdi-cloud-tags',  path: '/endpoints' },
  { title: 'pages.services', icon: 'mdi-server',  path: '/services' },
  { title: 'pages.servers', icon: 'mdi-server-network',  path: '/servers' },
  { title: 'pages.tls', icon: 'mdi-certificate',  path: '/tls' },
  { title: 'pages.basics', icon: 'mdi-application-cog',  path: '/basics' },
  { title: 'pages.rules', icon: 'mdi-routes',  path: '/rules' },
  { title: 'pages.dns', icon: 'mdi-dns',  path: '/dns' },
  { title: 'pages.admins', icon: 'mdi-account-tie',  path: '/admins' },
  { title: 'pages.settings', icon: 'mdi-cog',  path: '/settings' },
]

const Logout = async () => {
  logout()
}
</script>