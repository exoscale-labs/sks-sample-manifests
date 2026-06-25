package gateway

import "encoding/json"

// GatewayState is the resolved per-EgressGateway state the agent enforces.
type GatewayState struct {
	Name             string   `json:"name"`
	EIP              string   `json:"eip"`
	ActiveNode       string   `json:"activeNode"`
	GatewayPrivateIP string   `json:"gatewayPrivateIP"`
	Destinations     []string `json:"destinations"`
	PublicIface      string   `json:"publicIface"`
	PrivateIface     string   `json:"privateIface"`
}

// State is the full document written to the exegress-state ConfigMap.
type State struct {
	Gateways []GatewayState `json:"gateways"`
}

// JSON serialises the state for the ConfigMap (stable, indented).
func (s State) JSON() (string, error) {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// ParseState parses the ConfigMap document. An empty string yields a zero State.
func ParseState(s string) (State, error) {
	var out State
	if s == "" {
		return out, nil
	}
	if err := json.Unmarshal([]byte(s), &out); err != nil {
		return State{}, err
	}
	return out, nil
}
