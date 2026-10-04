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

// PanelRepoPlaceholder marks a checkout that was never pointed at a real
// repository. setrepo.sh replaces every occurrence of it, so meeting this value
// at runtime means the panel has no idea where its own releases live.
const PanelRepoPlaceholder = "OWNER/REPO"

// PanelRepoDefault is the repository this build publishes itself to. setrepo.sh
// rewrites it to the fork you are releasing from, and release CI overrides it at
// link time with -X, so a release build always knows where to fetch its own
// updates from without a code change.
const PanelRepoDefault = "Huzhao-1991/s-ui-mo"

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

// PanelRepoConfigured reports whether the effective repository is a real one.
//
// The check must be against PanelRepoPlaceholder, never against
// PanelRepoDefault: once setrepo.sh has run, the default *is* the real
// repository, so comparing with it would report every properly configured
// build as unconfigured and disable the panel's self-update.
func PanelRepoConfigured() bool {
	repo := GetPanelRepo()
	return repo != "" && repo != PanelRepoPlaceholder
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
