package gateway

import (
	"reflect"
	"testing"
)

func TestStateRoundTrip(t *testing.T) {
	in := State{Gateways: []GatewayState{{
		Name:             "mail-relay",
		EIP:              "185.150.8.200",
		ActiveNode:       "pool-a",
		GatewayPrivateIP: "172.28.0.176",
		Destinations:     []string{"192.0.2.25/32"},
		PublicIface:      "eth0",
		PrivateIface:     "eth1",
	}}}

	s, err := in.JSON()
	if err != nil {
		t.Fatal(err)
	}
	out, err := ParseState(s)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(in, out) {
		t.Fatalf("round-trip mismatch:\n in=%+v\nout=%+v", in, out)
	}
}

func TestParseEmpty(t *testing.T) {
	out, err := ParseState("")
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Gateways) != 0 {
		t.Fatalf("want empty, got %+v", out)
	}
}
