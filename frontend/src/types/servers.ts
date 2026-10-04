// A saved panel address — one row of the launcher, mirroring
// database/model/server.go. Two uses share the shape: with an empty token the
// entry is just a bookmark, with a token it is a panel this UI can manage.
export interface Server {
  id?: number
  name: string
  url: string
  token?: string
  remark?: string
}
