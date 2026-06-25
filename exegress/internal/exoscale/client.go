// Package exoscale wraps the egoscale v3 API behind a small interface so the
// controller can be tested with an in-memory fake.
package exoscale

import "context"

// Exo is the minimal Exoscale API surface the controller needs.
//
// All identifiers are string UUIDs. Instance names match the Kubernetes node
// names for SKS nodepool members.
type Exo interface {
	// InstanceIDByName resolves an instance (node) name to its UUID.
	InstanceIDByName(ctx context.Context, name string) (string, error)
	// InstancePrivateIP returns the instance's lease IP on the given private network.
	InstancePrivateIP(ctx context.Context, instanceID, privateNetworkID string) (string, error)
	// ElasticIPAddress returns the IP address of an Elastic IP.
	ElasticIPAddress(ctx context.Context, eipID string) (string, error)
	// InstancesAttachedToEIP returns the instance UUIDs the EIP is currently attached to.
	InstancesAttachedToEIP(ctx context.Context, eipID string) ([]string, error)
	// AttachEIP attaches the Elastic IP to the instance (idempotent at the API level).
	AttachEIP(ctx context.Context, eipID, instanceID string) error
	// DetachEIP detaches the Elastic IP from the instance.
	DetachEIP(ctx context.Context, eipID, instanceID string) error

	// DBaaSService returns a DBaaS service's type, endpoint host(s) and current
	// ip-filter. Used to resolve dynamic destinations and manage the allowlist.
	DBaaSService(ctx context.Context, name string) (svcType string, hosts []string, ipFilter []string, err error)
	// SetDBaaSIPFilter sets the ip-filter of the named service (dispatched by type).
	SetDBaaSIPFilter(ctx context.Context, name, svcType string, filter []string) error
}
