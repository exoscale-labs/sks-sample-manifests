package exoscale

import (
	"context"
	"fmt"
	"net/url"
	"strings"

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

// dbaasTypeOf resolves a DBaaS service name to its type (pg, mysql, ...).
func (e *egoClient) dbaasTypeOf(ctx context.Context, name string) (string, error) {
	list, err := e.c.ListDBAASServices(ctx)
	if err != nil {
		return "", fmt.Errorf("list dbaas services: %w", err)
	}
	for _, s := range list.DBAASServices {
		if string(s.Name) == name {
			return string(s.Type), nil
		}
	}
	return "", fmt.Errorf("dbaas service %q not found", name)
}

func (e *egoClient) DBaaSService(ctx context.Context, name string) (string, []string, []string, error) {
	typ, err := e.dbaasTypeOf(ctx, name)
	if err != nil {
		return "", nil, nil, err
	}
	var uri string
	var ipf []string
	switch typ {
	case "pg":
		s, err := e.c.GetDBAASServicePG(ctx, name)
		if err != nil {
			return "", nil, nil, err
		}
		uri, ipf = s.URI, s.IPFilter
	case "mysql":
		s, err := e.c.GetDBAASServiceMysql(ctx, name)
		if err != nil {
			return "", nil, nil, err
		}
		uri, ipf = s.URI, s.IPFilter
	case "valkey":
		s, err := e.c.GetDBAASServiceValkey(ctx, name)
		if err != nil {
			return "", nil, nil, err
		}
		uri, ipf = s.URI, s.IPFilter
	case "opensearch":
		s, err := e.c.GetDBAASServiceOpensearch(ctx, name)
		if err != nil {
			return "", nil, nil, err
		}
		uri, ipf = s.URI, s.IPFilter
	case "kafka":
		s, err := e.c.GetDBAASServiceKafka(ctx, name)
		if err != nil {
			return "", nil, nil, err
		}
		uri, ipf = s.URI, s.IPFilter
	case "grafana":
		s, err := e.c.GetDBAASServiceGrafana(ctx, name)
		if err != nil {
			return "", nil, nil, err
		}
		uri, ipf = s.URI, s.IPFilter
	default:
		return "", nil, nil, fmt.Errorf("dbaas service %q has unsupported type %q", name, typ)
	}
	return typ, hostsFromURI(uri), ipf, nil
}

func (e *egoClient) SetDBaaSIPFilter(ctx context.Context, name, svcType string, filter []string) error {
	var op *v3.Operation
	var err error
	switch svcType {
	case "pg":
		op, err = e.c.UpdateDBAASServicePG(ctx, name, v3.UpdateDBAASServicePGRequest{IPFilter: filter})
	case "mysql":
		op, err = e.c.UpdateDBAASServiceMysql(ctx, name, v3.UpdateDBAASServiceMysqlRequest{IPFilter: filter})
	case "valkey":
		op, err = e.c.UpdateDBAASServiceValkey(ctx, name, v3.UpdateDBAASServiceValkeyRequest{IPFilter: filter})
	case "opensearch":
		op, err = e.c.UpdateDBAASServiceOpensearch(ctx, name, v3.UpdateDBAASServiceOpensearchRequest{IPFilter: filter})
	case "kafka":
		op, err = e.c.UpdateDBAASServiceKafka(ctx, name, v3.UpdateDBAASServiceKafkaRequest{IPFilter: filter})
	case "grafana":
		op, err = e.c.UpdateDBAASServiceGrafana(ctx, name, v3.UpdateDBAASServiceGrafanaRequest{IPFilter: filter})
	default:
		return fmt.Errorf("dbaas service %q has unsupported type %q", name, svcType)
	}
	if err != nil {
		return fmt.Errorf("update dbaas %q ip-filter: %w", name, err)
	}
	if _, err := e.c.Wait(ctx, op, v3.OperationStateSuccess); err != nil {
		return fmt.Errorf("wait dbaas ip-filter update: %w", err)
	}
	return nil
}

// hostsFromURI extracts the hostname from a DBaaS connection URI such as
// "postgres://user:pass@host:port/db?sslmode=require".
func hostsFromURI(uri string) []string {
	uri = strings.TrimSpace(uri)
	if uri == "" {
		return nil
	}
	u, err := url.Parse(uri)
	if err != nil || u.Hostname() == "" {
		return nil
	}
	return []string{u.Hostname()}
}
