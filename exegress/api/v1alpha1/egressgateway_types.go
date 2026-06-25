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
	// Destinations is the list of CIDRs whose traffic is routed through the
	// gateway node and SNAT'd to the Elastic IP.
	// +kubebuilder:validation:MinItems=1
	Destinations []string `json:"destinations"`
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
