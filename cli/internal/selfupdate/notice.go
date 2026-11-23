package selfupdate

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// Interactive reports whether all three command streams refer to terminals.
// TIOCGWINSZ is available on each supported Darwin and Linux target.
func Interactive(stdin io.Reader, stdout, stderr io.Writer) bool {
	for _, stream := range []any{stdin, stdout, stderr} {
		f, ok := stream.(*os.File)
		if !ok || f == nil {
			return false
		}
		var winsize [4]uint16
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&winsize)))
		if errno != 0 {
			return false
		}
	}
	return true
}

type noticeState struct {
	Announced string
	Pages     map[string]page
}

// Notice returns one line for stderr, or "" when quiet. Call it only for
// ordinary commands. interactive must indicate that stdin, stdout and stderr
// are all terminals. Network and local-state failures never fail the command.
func Notice(ctx context.Context, installedVersion string, interactive, jsonOutput bool) string {
	if !interactive || jsonOutput {
		return ""
	}
	u, err := defaults()
	if err != nil {
		return ""
	}
	return u.notice(ctx, installedVersion, interactive, jsonOutput)
}

func (u updater) notice(ctx context.Context, installed string, interactive, jsonOutput bool) string {
	if !interactive || jsonOutput || !stableTag.MatchString(installed) {
		return ""
	}
	lock, err := u.lock("notice.lock")
	if err != nil {
		return ""
	}
	defer lock.Close()
	path := filepath.Join(u.state, "notice.json")
	var cached noticeState
	if data, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(data, &cached); err != nil {
			cached = noticeState{}
		}
	}
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	latest, pages, err := u.latest(ctx, cached.Pages)
	if err != nil {
		return ""
	}
	cached.Pages = pages
	var message string
	if newer(latest, installed) && (!stableTag.MatchString(cached.Announced) || newer(latest, cached.Announced)) {
		cached.Announced = latest
		message = fmt.Sprintf("Foreman CLI %s is available (installed %s). Run foreman update.", strings.TrimPrefix(latest, "v"), strings.TrimPrefix(installed, "v"))
	}
	data, err := json.Marshal(cached)
	if err != nil || atomicWrite(path, data) != nil {
		return ""
	}
	return message
}
