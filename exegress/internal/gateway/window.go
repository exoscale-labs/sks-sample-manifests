package gateway

import (
	"sort"
	"time"
)

// IPWindow tracks resolved IPs with a rolling grace period: an IP stays
// "active" for `grace` after it was last observed in DNS. This absorbs
// short-TTL churn and lets connections to a departed IP drain instead of
// breaking the instant the record disappears.
type IPWindow struct {
	grace time.Duration
	seen  map[string]time.Time
}

// NewIPWindow returns a window with the given grace period.
func NewIPWindow(grace time.Duration) *IPWindow {
	return &IPWindow{grace: grace, seen: map[string]time.Time{}}
}

// Observe records that the given IPs were seen at time now.
func (w *IPWindow) Observe(ips []string, now time.Time) {
	for _, ip := range ips {
		w.seen[ip] = now
	}
}

// Active returns the IPs seen within the grace period (sorted), pruning the
// rest from internal state.
func (w *IPWindow) Active(now time.Time) []string {
	out := make([]string, 0, len(w.seen))
	for ip, last := range w.seen {
		if now.Sub(last) <= w.grace {
			out = append(out, ip)
		} else {
			delete(w.seen, ip)
		}
	}
	sort.Strings(out)
	return out
}
