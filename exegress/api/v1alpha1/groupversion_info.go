// Package v1alpha1 contains the exegress.io/v1alpha1 API types.
// +kubebuilder:object:generate=true
// +groupName=exegress.io
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

// GroupVersion is the group/version used to register these objects.
var GroupVersion = schema.GroupVersion{Group: "exegress.io", Version: "v1alpha1"}

// SchemeBuilder registers the API types with a scheme.
var SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

// AddToScheme adds the types in this group-version to the given scheme.
var AddToScheme = SchemeBuilder.AddToScheme
