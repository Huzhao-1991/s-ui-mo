package model

// Server is a saved panel address — a "launcher" entry pointing at another
// panel (this fork, upstream s-ui, 3x-ui, anything).
//
// Two uses share one row:
//   - Token empty: clicking the entry just opens Url in a new tab.
//   - Token set: the central panel can manage that instance from this UI. The
//     browser sends an X-Remote-Server header and the API layer forwards the
//     request to <Url>/apiv2/<action> using Token.
//
// Named Server rather than something with "Panel" in it, because PanelService
// already means "this running process" and ServerService already means "this
// host's CPU/memory".
type Server struct {
	Id     uint   `json:"id" form:"id" gorm:"primaryKey;autoIncrement"`
	Name   string `json:"name" form:"name"`
	Url    string `json:"url" form:"url"`
	Token  string `json:"token" form:"token"`
	Remark string `json:"remark" form:"remark"`
}
