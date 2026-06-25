package gateway

import "testing"

func TestSelectActiveNode(t *testing.T) {
	nodes := []NodeInfo{{"b", true}, {"a", true}}

	if got, ok := SelectActiveNode(nodes, ""); !ok || got != "a" {
		t.Fatalf("first pick: want a,true got %q,%v", got, ok)
	}
	if got, _ := SelectActiveNode(nodes, "b"); got != "b" {
		t.Fatalf("sticky: want b got %q", got)
	}

	nf := []NodeInfo{{"b", true}, {"a", false}}
	if got, _ := SelectActiveNode(nf, "a"); got != "b" {
		t.Fatalf("failover: want b got %q", got)
	}

	if _, ok := SelectActiveNode([]NodeInfo{{"a", false}}, "a"); ok {
		t.Fatal("no ready node: want ok=false")
	}
	if _, ok := SelectActiveNode(nil, "x"); ok {
		t.Fatal("empty: want ok=false")
	}
}
