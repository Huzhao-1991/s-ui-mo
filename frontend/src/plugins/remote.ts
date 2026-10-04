// Which panel the UI is currently driving. Empty means "the one that served
// this page".
//
// This lives in its own module rather than in httputil so that api.ts can read
// it: httputil imports api, so api importing httputil back would close the
// cycle. api.ts attaches the header, everyone else reads and sets the value.
const STORAGE_KEY = 'remoteServer'

// Read once at module load. The selection is a property of the browser, not of
// the session, so it survives a reload -- otherwise refreshing the page while
// managing a remote would silently drop you back onto the local panel with no
// visible sign that the switch happened.
let current = localStorage.getItem(STORAGE_KEY) ?? ''

export function setRemoteServer(id: string | number | null): void {
  current = id ? String(id) : ''
  if (current) {
    localStorage.setItem(STORAGE_KEY, current)
  } else {
    localStorage.removeItem(STORAGE_KEY)
  }
}

export function getRemoteServer(): string {
  return current
}
