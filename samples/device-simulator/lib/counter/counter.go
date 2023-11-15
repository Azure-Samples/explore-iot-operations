// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package counter contains the counter-based implementations of a Provider.
// Counter Providers represent and wrap the counterVec prometheus metrics.
package counter

import (
	"fmt"

	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/explore-iot-ops/samples/device-simulator/lib/errors"

	"github.com/prometheus/client_golang/prometheus"
)

// Provider is an implementation of the registry.Provider interface.
// Its purpose is to register a new prometheus counterVec when created,
// And to create a counter (a prometheus counter with a provided label) when its with function is called.
type Provider struct {
	CounterVec *prometheus.CounterVec
	registry   prometheus.Registerer
	Name       string
	Help       string
	Label      string
}

const (
	SimulationCounterDefaultName = "simulation_counter"
	SimulationCounterDefaultHelp = "Simulation counter"
	CounterLabelKey              = "counter"
)

type InvalidPrometheusCounterVecNameError struct {
	errors.BadRequest
	name string
}

func (err *InvalidPrometheusCounterVecNameError) Error() string {
	return fmt.Sprintf(
		"could not create the counter provider with the name %s because the name has already been registered or is invalid",
		err.name,
	)
}

type InvalidPrometheusCounterLabelError struct {
	errors.BadRequest
	name  string
	label string
}

func (err *InvalidPrometheusCounterLabelError) Error() string {
	return fmt.Sprintf(
		"could not create the prometheus counter with label %s from counter provider %s because the label has already been used or is invalid",
		err.label,
		err.name,
	)
}

// New creates a Provider given a prometheus registerer.
// It can also take a function to set optional parameters.
func New(
	reg prometheus.Registerer,
	options ...func(*Provider),
) (*Provider, error) {
	counterProvider := &Provider{
		Name:     SimulationCounterDefaultName,
		Help:     SimulationCounterDefaultHelp,
		Label:    CounterLabelKey,
		registry: reg,
	}

	for _, option := range options {
		option(counterProvider)
	}

	counterProvider.CounterVec = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: counterProvider.Name,
			Help: counterProvider.Help,
		},
		[]string{counterProvider.Label},
	)

	err := counterProvider.registry.Register(counterProvider.CounterVec)

	if err != nil {
		return nil, &InvalidPrometheusCounterVecNameError{
			name: counterProvider.Name,
		}
	}

	return counterProvider, nil
}

// Cancel unregisters the prometheus counterVec from the prometheus registerer.
func (counterProvider *Provider) Cancel() error {
	counterProvider.registry.Unregister(counterProvider.CounterVec)
	return nil
}

// With attempts to create a Counter, which is a wrapper around the prometheus counter metric that implements the CancellableObservable interface.
// It returns an error if a failure is encountered.
func (counterProvider *Provider) With(
	label string,
) (registry.CancellableObservable, error) {

	counter, err := counterProvider.CounterVec.GetMetricWith(
		prometheus.Labels{counterProvider.Label: label},
	)

	if err != nil {
		return nil, &InvalidPrometheusCounterLabelError{
			name:  counterProvider.Name,
			label: label,
		}
	}

	return NewCounter(counterProvider.registry, counter), nil
}

// Counter is an implementation of CancellableObservable which wraps the functionality of the prometheus counter metric.
// It increments the counter when its observe function is called.
type Counter struct {
	observable prometheus.Counter
	registry   prometheus.Registerer
}

// NewCounter creates a Counter given a prometheus counter and a prometheus registerer.
func NewCounter(
	reg prometheus.Registerer,
	observable prometheus.Counter,
) *Counter {
	return &Counter{
		registry:   reg,
		observable: observable,
	}
}

// Cancel unregisters the prometheus counter from the registerer.
func (counter Counter) Cancel() {
	counter.registry.Unregister(counter.observable)
}

// Observe calls the increment function of the prometheus counter.
func (counter Counter) Observe(float64) {
	counter.observable.Inc()
}
