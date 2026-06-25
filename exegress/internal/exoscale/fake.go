package exoscale

import (
	"context"
	"fmt"
	"sort"
)

// Fake is an in-memory implementation of Exo for tests.
type Fake struct {
	// InstancesByName maps instance/node name -> instance UUID.
	InstancesByName map[string]string
	// PrivateIPs maps "instanceID/pnID" -> lease IP.
	PrivateIPs map[string]string
	// EIPAddr maps EIP UUID -> address.
	EIPAddr map[string]string
	// Attachments maps EIP UUID -> set of instance UUIDs.
	Attachments map[string][]string
	// DBaaS maps service name -> fake service (type, hosts, ip-filter).
	DBaaS map[string]*FakeDBaaS
}

// FakeDBaaS is a stand-in DBaaS service for tests.
type FakeDBaaS struct {
	Type     string
	Hosts    []string
	IPFilter []string
}

// NewFake returns an initialised Fake.
func NewFake() *Fake {
	return &Fake{
		InstancesByName: map[string]string{},
		PrivateIPs:      map[string]string{},
		EIPAddr:         map[string]string{},
		Attachments:     map[string][]string{},
		DBaaS:           map[string]*FakeDBaaS{},
	}
}

func (f *Fake) DBaaSService(_ context.Context, name string) (string, []string, []string, error) {
	s, ok := f.DBaaS[name]
	if !ok {
		return "", nil, nil, fmt.Errorf("dbaas service %q not found", name)
	}
	return s.Type, append([]string(nil), s.Hosts...), append([]string(nil), s.IPFilter...), nil
}

func (f *Fake) SetDBaaSIPFilter(_ context.Context, name, _ string, filter []string) error {
	s, ok := f.DBaaS[name]
	if !ok {
		return fmt.Errorf("dbaas service %q not found", name)
	}
	s.IPFilter = append([]string(nil), filter...)
	return nil
}

func (f *Fake) InstanceIDByName(_ context.Context, name string) (string, error) {
	id, ok := f.InstancesByName[name]
	if !ok {
		return "", fmt.Errorf("instance %q not found", name)
	}
	return id, nil
}

func (f *Fake) InstancePrivateIP(_ context.Context, instanceID, pnID string) (string, error) {
	ip, ok := f.PrivateIPs[instanceID+"/"+pnID]
	if !ok {
		return "", fmt.Errorf("no lease for instance %q on network %q", instanceID, pnID)
	}
	return ip, nil
}

func (f *Fake) ElasticIPAddress(_ context.Context, eipID string) (string, error) {
	addr, ok := f.EIPAddr[eipID]
	if !ok {
		return "", fmt.Errorf("elastic IP %q not found", eipID)
	}
	return addr, nil
}

func (f *Fake) InstancesAttachedToEIP(_ context.Context, eipID string) ([]string, error) {
	out := append([]string(nil), f.Attachments[eipID]...)
	sort.Strings(out)
	return out, nil
}

func (f *Fake) AttachEIP(_ context.Context, eipID, instanceID string) error {
	for _, id := range f.Attachments[eipID] {
		if id == instanceID {
			return nil
		}
	}
	f.Attachments[eipID] = append(f.Attachments[eipID], instanceID)
	return nil
}

func (f *Fake) DetachEIP(_ context.Context, eipID, instanceID string) error {
	cur := f.Attachments[eipID]
	out := cur[:0:0]
	for _, id := range cur {
		if id != instanceID {
			out = append(out, id)
		}
	}
	f.Attachments[eipID] = out
	return nil
}
