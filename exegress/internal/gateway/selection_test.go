package gateway

import "testing"

func n(name string, ready, sched bool) NodeInfo {
	return NodeInfo{Name: name, Ready: ready, Schedulable: sched}
}

func TestSelectActiveNode(t *testing.T) {
	nodes := []NodeInfo{n("b", true, true), n("a", true, true)}

	if got, ok := SelectActiveNode(nodes, ""); !ok || got != "a" {
		t.Fatalf("first pick: want a,true got %q,%v", got, ok)
	}
	if got, _ := SelectActiveNode(nodes, "b"); got != "b" {
		t.Fatalf("sticky: want b got %q", got)
	}

	// current NotReady -> failover
	if got, _ := SelectActiveNode([]NodeInfo{n("b", true, true), n("a", false, true)}, "a"); got != "b" {
		t.Fatalf("failover: want b got %q", got)
	}

	// current cordoned (Ready but unschedulable) + schedulable alternative -> move off it
	if got, _ := SelectActiveNode([]NodeInfo{n("a", true, false), n("b", true, true)}, "a"); got != "b" {
		t.Fatalf("cordon drain: want b got %q", got)
	}

	// current cordoned but NO schedulable alternative -> keep serving on a Ready node
	if got, ok := SelectActiveNode([]NodeInfo{n("a", true, false)}, "a"); !ok || got != "a" {
		t.Fatalf("cordon no-alt: want a,true got %q,%v", got, ok)
	}

	// nothing Ready
	if _, ok := SelectActiveNode([]NodeInfo{n("a", false, true)}, "a"); ok {
		t.Fatal("no ready node: want ok=false")
	}
	if _, ok := SelectActiveNode(nil, "x"); ok {
		t.Fatal("empty: want ok=false")
	}
}
