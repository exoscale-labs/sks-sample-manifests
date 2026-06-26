package controller

import (
	"context"
	"reflect"
	"testing"

	exegressv1alpha1 "github.com/coe-dev/exegress/api/v1alpha1"
	"github.com/coe-dev/exegress/internal/exoscale"
)

func reconciler(fake *exoscale.Fake, hosts map[string][]string) *EgressGatewayReconciler {
	return &EgressGatewayReconciler{
		Exo: fake,
		LookupHost: func(_ context.Context, h string) ([]string, error) {
			return hosts[h], nil
		},
	}
}

func egw(name string, spec exegressv1alpha1.EgressGatewaySpec) *exegressv1alpha1.EgressGateway {
	g := &exegressv1alpha1.EgressGateway{Spec: spec}
	g.Name = name
	return g
}

// Static CIDRs (single IPs + subnets) pass through verbatim, sorted+deduped,
// and are not treated as dynamic.
func TestResolveStaticIPsAndSubnets(t *testing.T) {
	r := reconciler(exoscale.NewFake(), nil)
	g := egw("static", exegressv1alpha1.EgressGatewaySpec{
		Destinations: []string{"198.51.100.0/24", "192.0.2.25/32", "192.0.2.25/32"},
	})

	got, dynamic, err := r.resolveDestinations(context.Background(), g, "203.0.113.1")
	if err != nil {
		t.Fatal(err)
	}
	if dynamic {
		t.Fatal("static-only should not be dynamic")
	}
	want := []string{"192.0.2.25/32", "198.51.100.0/24"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("want %v got %v", want, got)
	}
}

// DNS destinations resolve to /32s, merge with static CIDRs, and IPv6 is dropped.
func TestResolveDNSMergesAndDropsIPv6(t *testing.T) {
	r := reconciler(exoscale.NewFake(), map[string][]string{
		"a.example.com": {"10.0.0.5", "2001:db8::1"},
	})
	g := egw("dns", exegressv1alpha1.EgressGatewaySpec{
		Destinations:   []string{"192.0.2.25/32"},
		DestinationDNS: []string{"a.example.com"},
	})

	got, dynamic, err := r.resolveDestinations(context.Background(), g, "203.0.113.1")
	if err != nil {
		t.Fatal(err)
	}
	if !dynamic {
		t.Fatal("DNS source should be dynamic")
	}
	want := []string{"10.0.0.5/32", "192.0.2.25/32"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("want %v got %v", want, got)
	}
}

// DBaaS service endpoints are resolved and routed; the EIP is added to the
// service ip-filter add-only (idempotent across reconciles).
func TestResolveDBaaSAndIPFilter(t *testing.T) {
	fake := exoscale.NewFake()
	fake.DBaaS["pg1"] = &exoscale.FakeDBaaS{Type: "pg", Hosts: []string{"pg.host"}, IPFilter: nil}
	r := reconciler(fake, map[string][]string{"pg.host": {"10.1.1.1"}})
	g := egw("db", exegressv1alpha1.EgressGatewaySpec{
		DBaaSServices:       []string{"pg1"},
		ManageDBaaSIPFilter: true,
	})

	got, dynamic, err := r.resolveDestinations(context.Background(), g, "203.0.113.1")
	if err != nil {
		t.Fatal(err)
	}
	if !dynamic {
		t.Fatal("DBaaS source should be dynamic")
	}
	if !reflect.DeepEqual(got, []string{"10.1.1.1/32"}) {
		t.Fatalf("routed: want [10.1.1.1/32] got %v", got)
	}
	if !reflect.DeepEqual(fake.DBaaS["pg1"].IPFilter, []string{"203.0.113.1/32"}) {
		t.Fatalf("ip-filter: want [203.0.113.1/32] got %v", fake.DBaaS["pg1"].IPFilter)
	}

	// Reconcile again: ip-filter must not gain a duplicate entry (add-only).
	if _, _, err := r.resolveDestinations(context.Background(), g, "203.0.113.1"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fake.DBaaS["pg1"].IPFilter, []string{"203.0.113.1/32"}) {
		t.Fatalf("ip-filter not idempotent: got %v", fake.DBaaS["pg1"].IPFilter)
	}
}
