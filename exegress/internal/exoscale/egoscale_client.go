package exoscale

import (
	"context"
	"fmt"

	v3 "github.com/exoscale/egoscale/v3"
	"github.com/exoscale/egoscale/v3/credentials"
)

// egoClient implements Exo against the real Exoscale API (egoscale v3).
type egoClient struct {
	c *v3.Client
}

// New builds an Exo client scoped to the given zone (e.g. "de-fra-1").
func New(ctx context.Context, apiKey, apiSecret, zone string) (Exo, error) {
	creds := credentials.NewStaticCredentials(apiKey, apiSecret)
	c, err := v3.NewClient(creds)
	if err != nil {
		return nil, fmt.Errorf("new exoscale client: %w", err)
	}
	ep, err := c.GetZoneAPIEndpoint(ctx, v3.ZoneName(zone))
	if err != nil {
		return nil, fmt.Errorf("resolve zone %q endpoint: %w", zone, err)
	}
	return &egoClient{c: c.WithEndpoint(ep)}, nil
}

func (e *egoClient) InstanceIDByName(ctx context.Context, name string) (string, error) {
	resp, err := e.c.ListInstances(ctx)
	if err != nil {
		return "", fmt.Errorf("list instances: %w", err)
	}
	for _, in := range resp.Instances {
		if in.Name == name {
			return in.ID.String(), nil
		}
	}
	return "", fmt.Errorf("instance %q not found", name)
}

func (e *egoClient) InstancePrivateIP(ctx context.Context, instanceID, pnID string) (string, error) {
	pn, err := e.c.GetPrivateNetwork(ctx, v3.UUID(pnID))
	if err != nil {
		return "", fmt.Errorf("get private network %q: %w", pnID, err)
	}
	for _, l := range pn.Leases {
		if l.InstanceID.String() == instanceID {
			return l.IP.String(), nil
		}
	}
	return "", fmt.Errorf("no lease for instance %q on network %q", instanceID, pnID)
}

func (e *egoClient) ElasticIPAddress(ctx context.Context, eipID string) (string, error) {
	eip, err := e.c.GetElasticIP(ctx, v3.UUID(eipID))
	if err != nil {
		return "", fmt.Errorf("get elastic IP %q: %w", eipID, err)
	}
	return eip.IP, nil
}

func (e *egoClient) InstancesAttachedToEIP(ctx context.Context, eipID string) ([]string, error) {
	resp, err := e.c.ListInstances(ctx)
	if err != nil {
		return nil, fmt.Errorf("list instances: %w", err)
	}
	var out []string
	for _, li := range resp.Instances {
		in, err := e.c.GetInstance(ctx, li.ID)
		if err != nil {
			return nil, fmt.Errorf("get instance %q: %w", li.ID, err)
		}
		for _, eip := range in.ElasticIPS {
			if eip.ID.String() == eipID {
				out = append(out, in.ID.String())
				break
			}
		}
	}
	return out, nil
}

func (e *egoClient) AttachEIP(ctx context.Context, eipID, instanceID string) error {
	op, err := e.c.AttachInstanceToElasticIP(ctx, v3.UUID(eipID), v3.AttachInstanceToElasticIPRequest{
		Instance: &v3.InstanceTarget{ID: v3.UUID(instanceID)},
	})
	if err != nil {
		return fmt.Errorf("attach EIP %q to %q: %w", eipID, instanceID, err)
	}
	if _, err := e.c.Wait(ctx, op, v3.OperationStateSuccess); err != nil {
		return fmt.Errorf("wait attach EIP: %w", err)
	}
	return nil
}

func (e *egoClient) DetachEIP(ctx context.Context, eipID, instanceID string) error {
	op, err := e.c.DetachInstanceFromElasticIP(ctx, v3.UUID(eipID), v3.DetachInstanceFromElasticIPRequest{
		Instance: &v3.InstanceTarget{ID: v3.UUID(instanceID)},
	})
	if err != nil {
		return fmt.Errorf("detach EIP %q from %q: %w", eipID, instanceID, err)
	}
	if _, err := e.c.Wait(ctx, op, v3.OperationStateSuccess); err != nil {
		return fmt.Errorf("wait detach EIP: %w", err)
	}
	return nil
}
