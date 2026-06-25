// Package controller implements the EgressGateway reconciler.
package controller

import (
	"context"
	"fmt"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	exegressv1alpha1 "github.com/coe-dev/exegress/api/v1alpha1"
	"github.com/coe-dev/exegress/internal/exoscale"
	"github.com/coe-dev/exegress/internal/gateway"
)

const (
	defaultPublicIface     = "eth0"
	defaultPrivateIface    = "eth1"
	defaultResolveInterval = 30 * time.Second
	defaultDNSGrace        = 300 * time.Second
)

// EgressGatewayReconciler reconciles EgressGateway objects.
type EgressGatewayReconciler struct {
	client.Client
	Exo              exoscale.Exo
	PrivateNetworkID string
	StateNamespace   string
	StateConfigMap   string
	// LookupHost resolves a hostname to IP strings. Defaults to the system
	// resolver; overridable in tests.
	LookupHost func(ctx context.Context, host string) ([]string, error)

	mu      sync.Mutex
	windows map[string]*gateway.IPWindow // per-EgressGateway rolling IP window
}

// +kubebuilder:rbac:groups=exegress.io,resources=egressgateways,verbs=get;list;watch
// +kubebuilder:rbac:groups=exegress.io,resources=egressgateways/status,verbs=get;update;patch
// +kubebuilder:rbac:groups="",resources=nodes,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch;create;update;patch

// Reconcile drives one EgressGateway towards its desired state and refreshes the
// shared state ConfigMap consumed by the node agent.
func (r *EgressGatewayReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	l := log.FromContext(ctx)

	var egw exegressv1alpha1.EgressGateway
	if err := r.Get(ctx, req.NamespacedName, &egw); err != nil {
		if apierrors.IsNotFound(err) {
			r.forgetWindow(req.Name)
			// Object gone: drop it from the shared state.
			if err := r.writeState(ctx); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	eligible, err := r.eligibleNodes(ctx, egw.Spec.GatewayNodeSelector)
	if err != nil {
		return ctrl.Result{}, err
	}

	active, ok := gateway.SelectActiveNode(eligible, egw.Status.ActiveNode)
	if !ok {
		l.Info("no Ready eligible node available", "egw", egw.Name)
		r.setCondition(&egw, metav1.ConditionFalse, "NoEligibleNode", "no Ready eligible node available")
		egw.Status.ActiveNode = ""
		egw.Status.EIPAttached = false
		_ = r.Status().Update(ctx, &egw)
		return ctrl.Result{}, r.writeState(ctx)
	}

	eipID := egw.Spec.ElasticIP.ID
	instanceID, err := r.Exo.InstanceIDByName(ctx, active)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("resolve instance for node %q: %w", active, err)
	}
	privIP, err := r.Exo.InstancePrivateIP(ctx, instanceID, r.PrivateNetworkID)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("resolve private IP for node %q: %w", active, err)
	}

	if err := r.reconcileAttachment(ctx, eipID, instanceID); err != nil {
		return ctrl.Result{}, err
	}

	addr := egw.Spec.ElasticIP.Address
	if addr == "" {
		if addr, err = r.Exo.ElasticIPAddress(ctx, eipID); err != nil {
			return ctrl.Result{}, fmt.Errorf("resolve EIP address: %w", err)
		}
	}

	resolved, dynamic, err := r.resolveDestinations(ctx, &egw, addr)
	if err != nil {
		return ctrl.Result{}, err
	}

	egw.Status.ActiveNode = active
	egw.Status.ActiveNodePrivateIP = privIP
	egw.Status.EIPAttached = true
	egw.Status.ResolvedDestinations = resolved
	egw.Status.ObservedGeneration = egw.Generation
	r.setCondition(&egw, metav1.ConditionTrue, "Ready", fmt.Sprintf("EIP %s active on %s", addr, active))
	if err := r.Status().Update(ctx, &egw); err != nil {
		return ctrl.Result{}, err
	}

	if err := r.writeState(ctx); err != nil {
		return ctrl.Result{}, err
	}

	// Periodically re-resolve only when dynamic destinations are in play.
	if dynamic {
		return ctrl.Result{RequeueAfter: resolveInterval(&egw)}, nil
	}
	return ctrl.Result{}, nil
}

// resolveDestinations builds the routed CIDR set for a gateway: static CIDRs
// plus the rolling-window set of IPs resolved from DestinationDNS and DBaaS
// service endpoints. When manageDBaaSIPFilter is set, it also ensures the EIP
// is present in each referenced service's ip-filter (add-only). The bool return
// reports whether any dynamic source is configured.
func (r *EgressGatewayReconciler) resolveDestinations(ctx context.Context, egw *exegressv1alpha1.EgressGateway, eipAddr string) ([]string, bool, error) {
	l := log.FromContext(ctx)
	dynamic := len(egw.Spec.DestinationDNS) > 0 || len(egw.Spec.DBaaSServices) > 0

	hostnames := append([]string(nil), egw.Spec.DestinationDNS...)

	for _, svc := range egw.Spec.DBaaSServices {
		typ, hosts, ipFilter, err := r.Exo.DBaaSService(ctx, svc)
		if err != nil {
			return nil, dynamic, fmt.Errorf("dbaas service %q: %w", svc, err)
		}
		hostnames = append(hostnames, hosts...)

		if egw.Spec.ManageDBaaSIPFilter {
			eipCIDR := eipAddr + "/32"
			if !contains(ipFilter, eipCIDR) {
				if err := r.Exo.SetDBaaSIPFilter(ctx, svc, typ, append(ipFilter, eipCIDR)); err != nil {
					return nil, dynamic, fmt.Errorf("set ip-filter on %q: %w", svc, err)
				}
				l.Info("added EIP to DBaaS ip-filter", "service", svc, "eip", eipCIDR)
			}
		}
	}

	// Resolve hostnames (best-effort: a transient failure keeps prior IPs alive
	// via the rolling window rather than dropping routes).
	var resolvedIPs []string
	for _, h := range dedupeSorted(hostnames) {
		ips, err := r.lookup(ctx, h)
		if err != nil {
			l.Info("DNS resolution failed; relying on rolling window", "host", h, "err", err.Error())
			continue
		}
		for _, ip := range ips {
			if strings.Contains(ip, ":") {
				continue // skip IPv6 (v1 is IPv4-only)
			}
			resolvedIPs = append(resolvedIPs, ip)
		}
	}

	now := time.Now()
	var windowed []string
	if dynamic {
		w := r.windowFor(egw.Name, grace(egw))
		w.Observe(resolvedIPs, now)
		windowed = w.Active(now)
	}

	out := append([]string(nil), egw.Spec.Destinations...) // static CIDRs, simple path
	for _, ip := range windowed {
		out = append(out, ip+"/32")
	}
	return dedupeSorted(out), dynamic, nil
}

func (r *EgressGatewayReconciler) lookup(ctx context.Context, host string) ([]string, error) {
	if r.LookupHost != nil {
		return r.LookupHost(ctx, host)
	}
	return net.DefaultResolver.LookupHost(ctx, host)
}

func (r *EgressGatewayReconciler) windowFor(name string, g time.Duration) *gateway.IPWindow {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.windows == nil {
		r.windows = map[string]*gateway.IPWindow{}
	}
	w, ok := r.windows[name]
	if !ok {
		w = gateway.NewIPWindow(g)
		r.windows[name] = w
	}
	return w
}

func (r *EgressGatewayReconciler) forgetWindow(name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.windows, name)
}

func resolveInterval(egw *exegressv1alpha1.EgressGateway) time.Duration {
	if egw.Spec.ResolveIntervalSeconds > 0 {
		return time.Duration(egw.Spec.ResolveIntervalSeconds) * time.Second
	}
	return defaultResolveInterval
}

func grace(egw *exegressv1alpha1.EgressGateway) time.Duration {
	if egw.Spec.DNSGraceSeconds > 0 {
		return time.Duration(egw.Spec.DNSGraceSeconds) * time.Second
	}
	return defaultDNSGrace
}

// reconcileAttachment ensures the EIP is attached to instanceID and detached
// from any other instance.
func (r *EgressGatewayReconciler) reconcileAttachment(ctx context.Context, eipID, instanceID string) error {
	attached, err := r.Exo.InstancesAttachedToEIP(ctx, eipID)
	if err != nil {
		return fmt.Errorf("list EIP attachments: %w", err)
	}
	found := false
	for _, id := range attached {
		if id == instanceID {
			found = true
			continue
		}
		if err := r.Exo.DetachEIP(ctx, eipID, id); err != nil {
			return fmt.Errorf("detach EIP from %q: %w", id, err)
		}
	}
	if !found {
		if err := r.Exo.AttachEIP(ctx, eipID, instanceID); err != nil {
			return fmt.Errorf("attach EIP to %q: %w", instanceID, err)
		}
	}
	return nil
}

// eligibleNodes returns the nodes matching the selector with readiness and
// schedulability (cordoned nodes are flagged so the gateway moves off them).
func (r *EgressGatewayReconciler) eligibleNodes(ctx context.Context, sel metav1.LabelSelector) ([]gateway.NodeInfo, error) {
	ls, err := metav1.LabelSelectorAsSelector(&sel)
	if err != nil {
		return nil, fmt.Errorf("invalid gatewayNodeSelector: %w", err)
	}
	var nodes corev1.NodeList
	if err := r.List(ctx, &nodes, client.MatchingLabelsSelector{Selector: ls}); err != nil {
		return nil, err
	}
	out := make([]gateway.NodeInfo, 0, len(nodes.Items))
	for i := range nodes.Items {
		n := &nodes.Items[i]
		out = append(out, gateway.NodeInfo{
			Name:        n.Name,
			Ready:       nodeReady(n),
			Schedulable: !n.Spec.Unschedulable,
		})
	}
	return out, nil
}

func nodeReady(n *corev1.Node) bool {
	for _, c := range n.Status.Conditions {
		if c.Type == corev1.NodeReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// writeState rebuilds the aggregate state from all EgressGateways and writes the
// shared ConfigMap. The routed destination set comes from each gateway's
// resolved status (static + dynamic), so the agent is unaffected by the source.
func (r *EgressGatewayReconciler) writeState(ctx context.Context) error {
	var list exegressv1alpha1.EgressGatewayList
	if err := r.List(ctx, &list); err != nil {
		return err
	}
	var st gateway.State
	for i := range list.Items {
		egw := &list.Items[i]
		if egw.Status.ActiveNode == "" || !egw.Status.EIPAttached {
			continue
		}
		addr := egw.Spec.ElasticIP.Address
		if addr == "" {
			a, err := r.Exo.ElasticIPAddress(ctx, egw.Spec.ElasticIP.ID)
			if err != nil {
				return err
			}
			addr = a
		}
		dests := egw.Status.ResolvedDestinations
		if len(dests) == 0 {
			dests = egw.Spec.Destinations
		}
		st.Gateways = append(st.Gateways, gateway.GatewayState{
			Name:             egw.Name,
			EIP:              addr,
			ActiveNode:       egw.Status.ActiveNode,
			GatewayPrivateIP: egw.Status.ActiveNodePrivateIP,
			Destinations:     dests,
			PublicIface:      ifaceOr(egw.Spec.Interfaces.Public, defaultPublicIface),
			PrivateIface:     ifaceOr(egw.Spec.Interfaces.Private, defaultPrivateIface),
		})
	}
	sort.Slice(st.Gateways, func(i, j int) bool { return st.Gateways[i].Name < st.Gateways[j].Name })

	doc, err := st.JSON()
	if err != nil {
		return err
	}

	var cm corev1.ConfigMap
	key := types.NamespacedName{Namespace: r.StateNamespace, Name: r.StateConfigMap}
	err = r.Get(ctx, key, &cm)
	switch {
	case apierrors.IsNotFound(err):
		cm = corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Namespace: r.StateNamespace, Name: r.StateConfigMap},
			Data:       map[string]string{"state.json": doc},
		}
		return r.Create(ctx, &cm)
	case err != nil:
		return err
	default:
		if cm.Data == nil {
			cm.Data = map[string]string{}
		}
		cm.Data["state.json"] = doc
		return r.Update(ctx, &cm)
	}
}

func ifaceOr(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

func dedupeSorted(in []string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s == "" {
			continue
		}
		if _, ok := seen[s]; ok {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

func (r *EgressGatewayReconciler) setCondition(egw *exegressv1alpha1.EgressGateway, status metav1.ConditionStatus, reason, msg string) {
	meta := metav1.Condition{
		Type:               "Ready",
		Status:             status,
		Reason:             reason,
		Message:            msg,
		ObservedGeneration: egw.Generation,
		LastTransitionTime: metav1.Now(),
	}
	for i, c := range egw.Status.Conditions {
		if c.Type == "Ready" {
			if c.Status == status {
				meta.LastTransitionTime = c.LastTransitionTime
			}
			egw.Status.Conditions[i] = meta
			return
		}
	}
	egw.Status.Conditions = append(egw.Status.Conditions, meta)
}

// SetupWithManager registers the reconciler and a Node watch that re-enqueues
// all EgressGateways (so failover triggers on node readiness/cordon changes).
func (r *EgressGatewayReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&exegressv1alpha1.EgressGateway{}).
		Watches(&corev1.Node{}, handler.EnqueueRequestsFromMapFunc(r.mapNodeToGateways)).
		Complete(r)
}

func (r *EgressGatewayReconciler) mapNodeToGateways(ctx context.Context, _ client.Object) []reconcile.Request {
	var list exegressv1alpha1.EgressGatewayList
	if err := r.List(ctx, &list); err != nil {
		return nil
	}
	reqs := make([]reconcile.Request, 0, len(list.Items))
	for _, egw := range list.Items {
		reqs = append(reqs, reconcile.Request{NamespacedName: types.NamespacedName{Name: egw.Name}})
	}
	return reqs
}
