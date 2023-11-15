// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package provider

import (
	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/prometheus/client_golang/prometheus"
)

// Provider is the interface describing the provider component.
// Its implementations should be able to create a CancellableObservable implementation if provided with a label.
type Provider interface {
	With(label string) (registry.CancellableObservable, error)
	Cancel() error
}

type MockProvider struct {
	OnWith   func(label string) (registry.CancellableObservable, error)
	OnCancel func() error
}

func (provider *MockProvider) With(
	label string,
) (registry.CancellableObservable, error) {
	return provider.OnWith(label)
}

func (provider *MockProvider) Cancel() error {
	return provider.OnCancel()
}

type MockRegistry struct {
	prometheus.Registerer
	OnRegister     func(prometheus.Collector) error
	OnMustRegister func(...prometheus.Collector)
	OnUnregister   func(prometheus.Collector) bool
}

func (reg *MockRegistry) Register(c prometheus.Collector) error {
	return reg.OnRegister(c)
}

func (reg *MockRegistry) MustRegister(c ...prometheus.Collector) {
	reg.OnMustRegister(c...)
}

func (reg *MockRegistry) Unregister(c prometheus.Collector) bool {
	return reg.OnUnregister(c)
}
