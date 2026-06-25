// Package gateway holds the controller's pure decision logic: which node is the
// active gateway, and the on-wire state shared with the node agent.
package gateway

import "sort"

// NodeInfo is the minimal node view the selector needs.
type NodeInfo struct {
	Name  string
	Ready bool
}

// SelectActiveNode picks the active gateway node from the eligible set.
//
// It is sticky: if current is still eligible and Ready it is kept, avoiding
// needless EIP failover. Otherwise the lowest-sorted Ready eligible node is
// chosen for determinism. Returns ("", false) when no Ready node exists.
func SelectActiveNode(eligible []NodeInfo, current string) (string, bool) {
	byName := make(map[string]bool, len(eligible))
	for _, n := range eligible {
		byName[n.Name] = n.Ready
	}
	if current != "" {
		if ready, ok := byName[current]; ok && ready {
			return current, true
		}
	}

	names := make([]string, 0, len(eligible))
	for _, n := range eligible {
		if n.Ready {
			names = append(names, n.Name)
		}
	}
	if len(names) == 0 {
		return "", false
	}
	sort.Strings(names)
	return names[0], true
}
