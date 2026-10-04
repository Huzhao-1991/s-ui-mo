package service

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/alireza0/s-ui/config"
	"github.com/alireza0/s-ui/logger"
)

type PanelService struct {
}

func (s *PanelService) RestartPanel(delay time.Duration) error {
	p, err := os.FindProcess(syscall.Getpid())
	if err != nil {
		return err
	}
	go func() {
		time.Sleep(delay)
		if runtime.GOOS == "windows" {
			err = p.Kill()
		} else {
			err = p.Signal(syscall.SIGHUP)
		}
		if err != nil {
			logger.Error("send signal SIGHUP failed:", err)
		}
	}()
	return nil
}

// PanelUpdateInfo is the answer to "is there a newer build of this panel".
type PanelUpdateInfo struct {
	CurrentVersion  string `json:"currentVersion"`
	LatestVersion   string `json:"latestVersion"`
	UpdateAvailable bool   `json:"updateAvailable"`
	Repo            string `json:"repo"`
}

const (
	// There is no separate update.sh: upgrading is re-running install.sh.
	// That is safe because the installer only mints a random account, password
	// and panel path when db/s-ui.db does not exist yet. An existing install
	// takes the "keep current settings" branch, so a click in the Web UI can
	// never lock the operator out of their own panel. The SUI_AUTO branch added
	// for this feature preserves the same rule.
	maxPanelUpdaterBytes = 2 << 20
)

func panelUpdaterURL(repo string) string {
	return fmt.Sprintf("https://raw.githubusercontent.com/%s/main/install.sh", repo)
}

func panelReleaseAPI(repo string) string {
	return fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", repo)
}

// GetUpdateInfo asks GitHub for the newest release of the tracked repository
// and compares it with the version this binary was built from.
func (s *PanelService) GetUpdateInfo() (*PanelUpdateInfo, error) {
	repo := config.GetPanelRepo()
	if repo == "" || repo == config.PanelRepoDefault {
		return nil, fmt.Errorf("panel repository is not configured; set SUI_PANEL_REPO or build with -X config.PanelRepo=owner/repo")
	}
	latest, err := fetchLatestPanelVersion(repo)
	if err != nil {
		return nil, err
	}
	current := config.GetVersion()
	return &PanelUpdateInfo{
		CurrentVersion:  current,
		LatestVersion:   latest,
		UpdateAvailable: isNewerVersion(latest, current),
		Repo:            repo,
	}, nil
}

// StartUpdate launches the upgrade outside the current request.
//
// The hard part is outliving the process being replaced. install.sh restarts
// s-ui at the end; if the updater were a child of the panel it would be killed
// along with it mid-install, leaving a half-written tree behind. So the job is
// started as its own systemd unit where systemd is available, and otherwise
// detached from the process group with setsid (containers, no-systemd boxes).
func (s *PanelService) StartUpdate() error {
	if runtime.GOOS != "linux" {
		return fmt.Errorf("panel web update is supported only on Linux installations")
	}
	repo := config.GetPanelRepo()
	if repo == "" || repo == config.PanelRepoDefault {
		return fmt.Errorf("panel repository is not configured; set SUI_PANEL_REPO or build with -X config.PanelRepo=owner/repo")
	}

	bash, err := exec.LookPath("bash")
	if err != nil {
		return fmt.Errorf("bash is required to run the panel updater: %w", err)
	}

	scriptPath, err := downloadPanelUpdater(repo)
	if err != nil {
		return err
	}

	// Delete the temporary script on the way out, success or failure.
	// SUI_AUTO=1 keeps the whole run non-interactive.
	updateScript := fmt.Sprintf("set -e; trap 'rm -f %s' EXIT; SUI_AUTO=1 %s %s",
		shellQuote(scriptPath), shellQuote(bash), shellQuote(scriptPath))

	if systemdRun, err := exec.LookPath("systemd-run"); err == nil {
		unitName := fmt.Sprintf("s-ui-web-update-%d", time.Now().Unix())
		cmd := exec.Command(systemdRun, "--unit", unitName, bash, "-lc", updateScript)
		out, err := cmd.CombinedOutput()
		if err != nil {
			output := strings.TrimSpace(string(out))
			// Not being under systemd is not an error -- it is a container or a
			// minimal image. Fall through to setsid; anything else is real.
			if !strings.Contains(output, "System has not been booted with systemd") &&
				!strings.Contains(output, "Failed to connect to bus") {
				_ = os.Remove(scriptPath)
				return fmt.Errorf("failed to start panel update job: %w: %s", err, output)
			}
			logger.Warning("systemd-run unavailable, falling back to detached update process: ", output)
		} else {
			logger.Info("started panel update job via systemd-run unit ", unitName)
			return nil
		}
	}

	cmd := exec.Command(bash, "-lc", "setsid "+updateScript+" >/dev/null 2>&1 </dev/null &")
	if err := cmd.Start(); err != nil {
		_ = os.Remove(scriptPath)
		return fmt.Errorf("failed to start panel update job: %w", err)
	}
	if err := cmd.Process.Release(); err != nil {
		logger.Warning("failed to release panel update process: ", err)
	}
	logger.Info("started detached panel update job")
	return nil
}

func downloadPanelUpdater(repo string) (string, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(panelUpdaterURL(repo))
	if err != nil {
		return "", fmt.Errorf("download panel updater: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download panel updater: unexpected HTTP %d", resp.StatusCode)
	}

	file, err := os.CreateTemp("", "s-ui-update-*.sh")
	if err != nil {
		return "", err
	}
	path := file.Name()
	ok := false
	defer func() {
		_ = file.Close()
		if !ok {
			_ = os.Remove(path)
		}
	}()

	// Capped, so a hijacked or wildly wrong response cannot fill the disk.
	n, err := io.Copy(file, io.LimitReader(resp.Body, maxPanelUpdaterBytes+1))
	if err != nil {
		return "", fmt.Errorf("write panel updater: %w", err)
	}
	if n > maxPanelUpdaterBytes {
		return "", fmt.Errorf("panel updater exceeds %d bytes", maxPanelUpdaterBytes)
	}
	if err := file.Chmod(0700); err != nil {
		return "", err
	}
	ok = true
	return path, nil
}

func fetchLatestPanelVersion(repo string) (string, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(panelReleaseAPI(repo))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GitHub API returned status %d", resp.StatusCode)
	}
	var release struct {
		TagName string `json:"tag_name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		return "", err
	}
	if release.TagName == "" {
		return "", fmt.Errorf("latest panel release tag is empty")
	}
	return release.TagName, nil
}

// Versions look like 1.6.3-mo1: three upstream numbers plus a fork suffix that
// CI derives from the tag. Compare the numbers first and only then the fork
// counter -- comparing the raw strings would leave "update available" lit
// forever whenever the local build carries a suffix and the release does not,
// or the moment the counter reaches double digits ("mo9" > "mo10" as text).
func isNewerVersion(latest, current string) bool {
	lMain, lRank, lNum, lOk := parseSuiVersion(latest)
	cMain, cRank, cNum, cOk := parseSuiVersion(current)
	if !lOk || !cOk {
		return normalizeVersionTag(latest) != normalizeVersionTag(current)
	}
	for i := range lMain {
		if lMain[i] != cMain[i] {
			return lMain[i] > cMain[i]
		}
	}
	// Same upstream version: a fork suffix outranks a bare release, because a
	// bare "1.6.3" is plain upstream and any suffix is a build on top of it.
	if lRank != cRank {
		return lRank > cRank
	}
	return lNum > cNum
}

// parseSuiVersion splits 1.6.3-mo12 into [1,6,3], a rank that is 0 for a bare
// upstream version and 1 for anything with a suffix, and the counter 12. ok is
// false when the three leading numbers are not all numeric.
func parseSuiVersion(version string) ([3]int, int, int, bool) {
	var main [3]int
	v := normalizeVersionTag(version)
	num := 0
	rank := 0
	if idx := strings.IndexAny(v, "-+"); idx >= 0 {
		suffix := v[idx+1:]
		v = v[:idx]
		if suffix != "" {
			rank = 1
			i := len(suffix)
			for i > 0 && suffix[i-1] >= '0' && suffix[i-1] <= '9' {
				i--
			}
			if n, err := strconv.Atoi(suffix[i:]); err == nil {
				num = n
			}
		}
	}
	parts := strings.Split(v, ".")
	if len(parts) != 3 {
		return main, 0, 0, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			return main, 0, 0, false
		}
		main[i] = n
	}
	return main, rank, num, true
}

func normalizeVersionTag(version string) string {
	return strings.TrimPrefix(strings.TrimSpace(version), "v")
}

// shellQuote wraps a value for safe interpolation into the shell command line
// that launches the updater.
func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
