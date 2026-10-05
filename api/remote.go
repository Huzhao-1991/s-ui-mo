package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/alireza0/s-ui/util/common"

	"github.com/gin-gonic/gin"
)

// remoteLocalOnly lists the actions that must always execute on the panel the
// browser is actually talking to, never on a remote it is proxying for. Server
// registry, authentication and token management are per-installation concerns;
// forwarding them would let a remote edit this panel's own credentials.
var remoteLocalOnly = map[string]bool{
	"servers":     true,
	"testServer":  true,
	"login":       true,
	"logout":      true,
	"tokens":      true,
	"addToken":    true,
	"deleteToken": true,
	"changePass":  true,
}

// remoteMiddleware forwards a request to another s-ui instance's APIv2 (token
// auth) whenever the browser sets X-Remote-Server, so the central panel can
// manage remote instances with the same UI instead of a second login.
//
// The header is set by the frontend from the selected server in the launcher;
// with nothing selected the request is handled locally and this is a no-op.
func (a *ApiService) remoteMiddleware(c *gin.Context) {
	serverId := c.GetHeader("X-Remote-Server")
	if serverId == "" {
		return
	}
	action := path.Base(c.Request.URL.Path)
	if remoteLocalOnly[action] {
		return
	}
	// The server registry is a central-panel concept, but its writes travel
	// through the generic "save" action, so the action name alone cannot tell
	// them apart -- object=servers lives in the body. Without this check a new
	// or deleted entry would be POSTed to the remote, which either errors out
	// or, worse, "succeeds" remotely while the local table never changes.
	if action == "save" && peekFormValue(c, "object") == "servers" {
		return
	}
	a.proxyToRemote(c, serverId, action)
	c.Abort()
}

// peekFormValue reads a single urlencoded form field without consuming the
// body. It buffers the body, parses a copy, then restores it so a request that
// does end up being proxied still forwards its complete payload.
func peekFormValue(c *gin.Context, key string) string {
	if c.Request.Body == nil {
		return ""
	}
	b, err := io.ReadAll(c.Request.Body)
	c.Request.Body = io.NopCloser(bytes.NewReader(b))
	if err != nil {
		return ""
	}
	vals, err := url.ParseQuery(string(b))
	if err != nil {
		return ""
	}
	return vals.Get(key)
}

// remoteCandidates expands a stored panel address into the base URLs worth
// trying, most specific first.
//
// The panel mounts its APIv2 under webPath -- "/app/" as shipped, but it is a
// setting the operator can change -- and its NoRoute handler answers a bare 404
// for every path outside that base. So "https://host:2095", which is how nearly
// every other service is configured, would fail with a 404 that says nothing
// about the real cause. The address as stored always comes first; the shipped
// default path is appended only when the address carries no path of its own, so
// a deliberately configured custom path is never second-guessed.
func remoteCandidates(raw string) ([]string, error) {
	base, err := normalizeRemoteBase(raw)
	if err != nil {
		return nil, err
	}
	bases := []string{base}
	if parsed, perr := url.Parse(base); perr == nil && (parsed.Path == "" || parsed.Path == "/") {
		bases = append(bases, base+"app/")
	}
	return bases, nil
}

func (a *ApiService) proxyToRemote(c *gin.Context, serverId string, action string) {
	server, err := a.ServerListService.GetById(serverId)
	if err != nil || server == nil || server.Url == "" {
		jsonMsg(c, "", common.NewError("remote server not found"))
		return
	}
	bases, err := remoteCandidates(server.Url)
	if err != nil {
		jsonMsg(c, "", err)
		return
	}
	if server.Token == "" {
		jsonMsg(c, "", common.NewError("remote server has no API token configured"))
		return
	}

	// Read the body once and replay it. A retry against the next candidate has
	// to carry the same payload; a one-shot reader would send the second
	// attempt empty and the remote would answer "unknown action" or worse.
	var payload []byte
	if c.Request.Method == http.MethodPost {
		payload, _ = io.ReadAll(c.Request.Body)
	}

	client := &http.Client{Timeout: 30 * time.Second}
	var resp *http.Response
	var respBody []byte
	for i, base := range bases {
		target := base + "apiv2/" + url.PathEscape(action)
		if c.Request.URL.RawQuery != "" {
			target += "?" + c.Request.URL.RawQuery
		}

		var body io.Reader
		if payload != nil {
			body = bytes.NewReader(payload)
		}
		req, reqErr := http.NewRequest(c.Request.Method, target, body)
		if reqErr != nil {
			jsonMsg(c, "", reqErr)
			return
		}
		req.Header.Set("Token", server.Token)
		if ct := c.Request.Header.Get("Content-Type"); ct != "" {
			req.Header.Set("Content-Type", ct)
		}

		resp, err = client.Do(req)
		if err != nil {
			jsonMsg(c, "", err)
			return
		}
		respBody, _ = io.ReadAll(resp.Body)
		_ = resp.Body.Close()

		// Only a 404 is worth a second attempt: NoRoute answers exactly that,
		// with an empty body, for any path outside the panel's base path.
		if resp.StatusCode != http.StatusNotFound || i == len(bases)-1 {
			break
		}
	}

	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/json"
	}
	c.Data(resp.StatusCode, contentType, respBody)
}

// normalizeRemoteBase validates a stored panel address and returns it with a
// trailing slash. Only http/https are accepted: a "file://" or bare host entry
// would otherwise be handed straight to http.NewRequest and fail with an
// opaque error instead of a message the operator can act on.
func normalizeRemoteBase(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", common.NewError("remote server url is empty")
	}
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", common.NewErrorf("remote server url is invalid: %v", err)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", common.NewErrorf("remote server url must be http or https, got %q", parsed.Scheme)
	}
	if parsed.Host == "" {
		return "", common.NewError("remote server url has no host")
	}
	out := strings.TrimSuffix(parsed.String(), "/") + "/"
	return out, nil
}

// TestServer probes a registered remote by calling its APIv2 status endpoint
// with the stored token and times the round trip. It reports latency and a
// short reason on failure, so the launcher can show whether the link really
// works instead of leaving the operator to guess from a blank page.
func (a *ApiService) TestServer(c *gin.Context) {
	id := c.Query("id")
	server, err := a.ServerListService.GetById(id)
	if err != nil || server == nil || server.Url == "" {
		jsonObj(c, gin.H{"online": false, "error": "server not found"}, nil)
		return
	}
	bases, err := remoteCandidates(server.Url)
	if err != nil {
		jsonObj(c, gin.H{"online": false, "error": err.Error()}, nil)
		return
	}

	client := &http.Client{Timeout: 8 * time.Second}
	reason := "unreachable"
	for _, base := range bases {
		req, reqErr := http.NewRequest(http.MethodGet, base+"apiv2/status", nil)
		if reqErr != nil {
			jsonObj(c, gin.H{"online": false, "error": reqErr.Error()}, nil)
			return
		}
		req.Header.Set("Token", server.Token)

		start := time.Now()
		resp, doErr := client.Do(req)
		latency := time.Since(start).Milliseconds()
		if doErr != nil {
			reason = "unreachable"
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()

		var parsed struct {
			Success bool `json:"success"`
		}
		isJSON := json.Unmarshal(body, &parsed) == nil

		if resp.StatusCode == http.StatusOK && isJSON {
			if !parsed.Success {
				// Reached a real s-ui APIv2 that refused the token. Trying the
				// other candidate cannot change that, so stop here rather than
				// reporting "unreachable" for a server that answered.
				jsonObj(c, gin.H{"online": false, "latency": latency, "error": "bad token"}, nil)
				return
			}
			jsonObj(c, gin.H{"online": true, "latency": latency, "base": base}, nil)
			return
		}
		if resp.StatusCode == http.StatusNotFound {
			reason = "http 404, check the url includes the panel path (default /app/)"
		} else {
			reason = "http " + strconv.Itoa(resp.StatusCode)
		}
	}

	jsonObj(c, gin.H{"online": false, "error": reason}, nil)
}
