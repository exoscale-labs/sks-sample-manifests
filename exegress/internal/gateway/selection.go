// Package gateway holds the controller's pure decision logic: which node is the
// active gateway, and the on-wire state shared with the node agent.
package gateway

import "sort"

// NodeInfo is the minimal node view the selector needs.
type NodeInfo struct {
	Name string
	// Ready is the Kubernetes NodeReady condition.
	Ready bool
	// Schedulable is false when the node is cordoned (spec.unschedulable),
	// which signals it is being drained / about to be removed.
	Schedulable bool
}

// SelectActiveNode picks the active gateway node from the eligible set.
//
// Preference order, for graceful drains and upgrades:
//   - a node must be Ready to be chosen at all;
//   - Ready AND Schedulable nodes are preferred (a cordoned node is being
//     drained, so we proactively move the gateway off it *before* it dies);
//   - sticky: the current node is kept only if it is still Ready and
//     Schedulable, avoiding needless EIP failover;
//   - if no Ready+Schedulable node exists, fall back to any Ready node (a
//     fully-cordoned but live cluster should still egress).
//
// Returns ("", false) when no Ready node exists.
func SelectActiveNode(eligible []NodeInfo, current string) (string, bool) {
	info := make(map[string]NodeInfo, len(eligible))
	for _, n := range eligible {
		info[n.Name] = n
	}

	// Stickiness: keep current only if it is Ready and Schedulable.
	if cur, ok := info[current]; ok && cur.Ready && cur.Schedulable {
		return current, true
	}

	var schedulable, ready []string
	for _, n := range eligible {
		if !n.Ready {
			continue
		}
		ready = append(ready, n.Name)
		if n.Schedulable {
			schedulable = append(schedulable, n.Name)
		}
	}

	switch {
	case len(schedulable) > 0:
		sort.Strings(schedulable)
		return schedulable[0], true
	case len(ready) > 0:
		sort.Strings(ready)
		return ready[0], true
	default:
		return "", false
	}
}
