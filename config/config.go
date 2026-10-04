package config

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

//go:embed version
var version string

//go:embed name
var name string

type LogLevel string

const (
	Debug LogLevel = "debug"
	Info  LogLevel = "info"
	Warn  LogLevel = "warn"
	Error LogLevel = "error"
)

func GetVersion() string {
	return strings.TrimSpace(version)
}

// PanelRepoDefault is used when nothing overrides it. Release CI rewrites this
// to the publishing repository via -ldflags -X, so a release build always knows
// where to fetch its own updates from without a code change.
const PanelRepoDefault = "OWNER/REPO"

// PanelRepo is the GitHub "owner/repo" this build checks for updates and pulls
// install.sh from. Overridden at build time with
//   -ldflags "-X github.com/alireza0/s-ui/config.PanelRepo=owner/repo"
var PanelRepo = PanelRepoDefault

// GetPanelRepo returns the effective owner/repo for update checks. The
// environment variable wins so an operator can point an existing binary at a
// mirror without rebuilding.
func GetPanelRepo() string {
	if env := strings.TrimSpace(os.Getenv("SUI_PANEL_REPO")); env != "" {
		return env
	}
	if repo := strings.TrimSpace(PanelRepo); repo != "" {
		return repo
	}
	return PanelRepoDefault
}

func GetName() string {
	return strings.TrimSpace(name)
}

func GetLogLevel() LogLevel {
	if IsDebug() {
		return Debug
	}
	logLevel := os.Getenv("SUI_LOG_LEVEL")
	if logLevel == "" {
		return Info
	}
	return LogLevel(logLevel)
}

func IsDebug() bool {
	return os.Getenv("SUI_DEBUG") == "true"
}

func GetDBFolderPath() string {
	dbFolderPath := os.Getenv("SUI_DB_FOLDER")
	if dbFolderPath == "" {
		dir, err := filepath.Abs(filepath.Dir(os.Args[0]))
		if err != nil {
			// Cross-platform fallback path
			if runtime.GOOS == "windows" {
				return "C:\\Program Files\\s-ui\\db"
			}
			return "/usr/local/s-ui/db"
		}
		dbFolderPath = filepath.Join(dir, "db")
	}
	return dbFolderPath
}

func GetDBPath() string {
	return fmt.Sprintf("%s/%s.db", GetDBFolderPath(), GetName())
}
