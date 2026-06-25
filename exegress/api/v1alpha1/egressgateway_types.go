package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ElasticIPRef references a pre-created, pinned Exoscale Elastic IP.
// The controller never creates or deletes Elastic IPs.
type ElasticIPRef struct {
	// ID is the Exoscale Elastic IP UUID.
	// +kubebuilder:validation:MinLength=1
	ID string `json:"id"`
	// Address is the EIP's IP address, used for validation and status visibility.
	// +optional
	Address string `json:"address,omitempty"`
}

// Interfaces optionally overrides the auto-detected node interface names.
type Interfaces struct {
	// Public is the public-facing interface on the node (default eth0).
	// +optional
	Public string `json:"public,omitempty"`
	// Private is the private-network interface on the node (default eth1).
	// +optional
	Private string `json:"private,omitempty"`
}

// EgressGatewaySpec defines the desired state of an EgressGateway.
type EgressGatewaySpec struct {
	// ElasticIP is the pinned EIP to use as the egress source.
	ElasticIP ElasticIPRef `json:"elasticIP"`
	// Destinations is the list of static CIDRs whose traffic is routed through
	// the gateway node and SNAT'd to the Elastic IP. These take the simple,
	// fully-static path (no DNS, no periodic resolution).
	// +optional
	Destinations []string `json:"destinations,omitempty"`
	// DestinationDNS is a list of hostnames (A records) the controller resolves
	// and refreshes; their current IPs are routed through the gateway.
	// +optional
	DestinationDNS []string `json:"destinationDNS,omitempty"`
	// DBaaSServices references Exoscale DBaaS services by name. The controller
	// resolves each service's endpoint host(s) via the DBaaS API, then DNS, and
	// routes the resulting IPs through the gateway.
	// +optional
	DBaaSServices []string `json:"dbaasServices,omitempty"`
	// ManageDBaaSIPFilter, when true, ensures the Elastic IP is present in the
	// ip-filter of each referenced DBaaS service. Add-only: existing entries
	// (including 0.0.0.0/0) are never removed.
	// +optional
	ManageDBaaSIPFilter bool `json:"manageDBaaSIPFilter,omitempty"`
	// ResolveIntervalSeconds is how often DNS/DBaaS destinations are refreshed.
	// Ignored when only static Destinations are set. Defaults to 30.
	// +optional
	ResolveIntervalSeconds int `json:"resolveIntervalSeconds,omitempty"`
	// DNSGraceSeconds keeps a resolved IP routed this long after it stops
	// appearing in DNS (rolling window for short-TTL / failover churn).
	// Defaults to 300.
	// +optional
	DNSGraceSeconds int `json:"dnsGraceSeconds,omitempty"`
	// GatewayNodeSelector selects nodes eligible to host the Elastic IP.
	GatewayNodeSelector metav1.LabelSelector `json:"gatewayNodeSelector"`
	// Interfaces optionally overrides node interface names.
	// +optional
	Interfaces Interfaces `json:"interfaces,omitempty"`
}

// EgressGatewayStatus defines the observed state of an EgressGateway.
type EgressGatewayStatus struct {
	// ActiveNode is the node currently holding the Elastic IP.
	// +optional
	ActiveNode string `json:"activeNode,omitempty"`
	// ActiveNodePrivateIP is the private-network IP of the active node.
	// +optional
	ActiveNodePrivateIP string `json:"activeNodePrivateIP,omitempty"`
	// EIPAttached reports whether the EIP is attached to the active node.
	// +optional
	EIPAttached bool `json:"eipAttached,omitempty"`
	// ResolvedDestinations is the current routed CIDR set (static + resolved).
	// +optional
	ResolvedDestinations []string `json:"resolvedDestinations,omitempty"`
	// ObservedGeneration is the spec generation last reconciled.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// Conditions represent the latest observations of the gateway's state.
	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,shortName=egw
// +kubebuilder:printcolumn:name="EIP",type=string,JSONPath=`.spec.elasticIP.address`
// +kubebuilder:printcolumn:name="Active Node",type=string,JSONPath=`.status.activeNode`
// +kubebuilder:printcolumn:name="Attached",type=boolean,JSONPath=`.status.eipAttached`

// EgressGateway is the Schema for the egressgateways API.
type EgressGateway struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   EgressGatewaySpec   `json:"spec,omitempty"`
	Status EgressGatewayStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// EgressGatewayList contains a list of EgressGateway.
type EgressGatewayList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []EgressGateway `json:"items"`
}

func init() {
	SchemeBuilder.Register(&EgressGateway{}, &EgressGatewayList{})
}
