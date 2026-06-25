// Command controller runs the exegress control plane. It can run in-cluster or
// out-of-cluster (honouring KUBECONFIG), the latter being convenient for tests.
package main

import (
	"context"
	"fmt"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	exegressv1alpha1 "github.com/coe-dev/exegress/api/v1alpha1"
	"github.com/coe-dev/exegress/internal/controller"
	"github.com/coe-dev/exegress/internal/exoscale"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)
	}
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func run() error {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log.WithName("setup")
	ctx := ctrl.SetupSignalHandler()

	apiKey := os.Getenv("EXOSCALE_API_KEY")
	apiSecret := os.Getenv("EXOSCALE_API_SECRET")
	zone := os.Getenv("EXOSCALE_ZONE")
	pnID := os.Getenv("EXEGRESS_PN_ID")
	if apiKey == "" || apiSecret == "" || zone == "" || pnID == "" {
		return fmt.Errorf("EXOSCALE_API_KEY, EXOSCALE_API_SECRET, EXOSCALE_ZONE, EXEGRESS_PN_ID are required")
	}
	stateNS := env("EXEGRESS_STATE_NAMESPACE", "kube-system")
	stateCM := env("EXEGRESS_STATE_CONFIGMAP", "exegress-state")

	exo, err := exoscale.New(context.Background(), apiKey, apiSecret, zone)
	if err != nil {
		return err
	}

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		return err
	}
	if err := exegressv1alpha1.AddToScheme(scheme); err != nil {
		return err
	}

	leaderElect := env("EXEGRESS_LEADER_ELECT", "false") == "true"
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                  scheme,
		LeaderElection:          leaderElect,
		LeaderElectionID:        "exegress-controller.exegress.io",
		LeaderElectionNamespace: stateNS,
	})
	if err != nil {
		return err
	}

	if err := (&controller.EgressGatewayReconciler{
		Client:           mgr.GetClient(),
		Exo:              exo,
		PrivateNetworkID: pnID,
		StateNamespace:   stateNS,
		StateConfigMap:   stateCM,
	}).SetupWithManager(mgr); err != nil {
		return err
	}

	log.Info("starting exegress controller", "zone", zone, "privateNetwork", pnID,
		"stateConfigMap", stateNS+"/"+stateCM)
	return mgr.Start(ctx)
}
