// Package controller implements the EgressGateway reconciler.
package controller

import (
	"context"
	"fmt"
	"sort"

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
	defaultPublicIface  = "eth0"
	defaultPrivateIface = "eth1"
)

// EgressGatewayReconciler reconciles EgressGateway objects.
type EgressGatewayReconciler struct {
	client.Client
	Exo              exoscale.Exo
	PrivateNetworkID string
	StateNamespace   string
	StateConfigMap   string
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

	egw.Status.ActiveNode = active
	egw.Status.ActiveNodePrivateIP = privIP
	egw.Status.EIPAttached = true
	egw.Status.ObservedGeneration = egw.Generation
	r.setCondition(&egw, metav1.ConditionTrue, "Ready", fmt.Sprintf("EIP %s active on %s", addr, active))
	if err := r.Status().Update(ctx, &egw); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, r.writeState(ctx)
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

// eligibleNodes returns the nodes matching the selector with their readiness.
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
	for _, n := range nodes.Items {
		out = append(out, gateway.NodeInfo{Name: n.Name, Ready: nodeReady(&n)})
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
// shared ConfigMap.
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
		st.Gateways = append(st.Gateways, gateway.GatewayState{
			Name:             egw.Name,
			EIP:              addr,
			ActiveNode:       egw.Status.ActiveNode,
			GatewayPrivateIP: egw.Status.ActiveNodePrivateIP,
			Destinations:     egw.Spec.Destinations,
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
// all EgressGateways (so failover triggers on node readiness changes).
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
