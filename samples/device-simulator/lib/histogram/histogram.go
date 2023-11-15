// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package histogram provides the histogram type implementation of the Provider interface.
// Histogram Providers represent the histogramVec prometheus metrics.
package histogram

import (
	"fmt"

	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/explore-iot-ops/samples/device-simulator/lib/errors"

	"github.com/prometheus/client_golang/prometheus"
)

// Provider is a registry.Provider implementation.
// Its purpose is to register a new prometheus histogramVec when created,
// And to create a histogram with a particular label when its with function is called.
type Provider struct {
	HistogramVec *prometheus.HistogramVec
	Name         string
	Help         string
	Label        string
	Start        float64
	Width        float64
	Buckets      int
	registry     prometheus.Registerer
}

const (
	SimulationHistogramDefaultName        = "simulation_histogram"
	SimulationHistogramDefaultHelp        = "Simulation histogram"
	SimulationHistogramDefaultBucketStart = 0
	SimulationHistogramDefaultBucketWidth = 1
	SimulationHistogramDefaultBucketCount = 1
	HistogramLabelKey                     = "histogram"
)

type InvalidHistogramParametersError struct {
	errors.BadRequest
	buckets int
	name    string
}

func (err *InvalidHistogramParametersError) Error() string {
	return fmt.Sprintf(
		"histogram provider with name %s had %d buckets specified, and there must be at least one bucket in a prometheus histogram",
		err.name,
		err.buckets,
	)
}

type InvalidPrometheusHistogramVecNameError struct {
	errors.BadRequest
	name string
}

func (err *InvalidPrometheusHistogramVecNameError) Error() string {
	return fmt.Sprintf(
		"could not create the histogram provider with the name %s because the name has already been registered or is invalid",
		err.name,
	)
}

type InvalidPrometheusHistogramLabelError struct {
	errors.BadRequest
	name  string
	label string
}

func (err *InvalidPrometheusHistogramLabelError) Error() string {
	return fmt.Sprintf(
		"could not create the prometheus histogram with label %s from histogram provider %s because the label has already been used or is invalid",
		err.label,
		err.name,
	)
}

// New creates a Provider, given a prometheus registerer.
// It can also take a function to set optional parameters.
func New(
	reg prometheus.Registerer,
	options ...func(*Provider),
) (*Provider, error) {
	histogramProvider := &Provider{
		Name:     SimulationHistogramDefaultName,
		Help:     SimulationHistogramDefaultHelp,
		Start:    SimulationHistogramDefaultBucketStart,
		Width:    SimulationHistogramDefaultBucketWidth,
		Buckets:  SimulationHistogramDefaultBucketCount,
		Label:    HistogramLabelKey,
		registry: reg,
	}

	for _, option := range options {
		option(histogramProvider)
	}

	if histogramProvider.Buckets <= 0 {
		return nil, &InvalidHistogramParametersError{
			buckets: histogramProvider.Buckets,
			name:    histogramProvider.Name,
		}
	}

	histogramProvider.HistogramVec = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name: histogramProvider.Name,
			Help: histogramProvider.Help,
			Buckets: prometheus.LinearBuckets(
				histogramProvider.Start,
				histogramProvider.Width,
				histogramProvider.Buckets,
			),
		},
		[]string{histogramProvider.Label},
	)

	err := reg.Register(histogramProvider.HistogramVec)

	if err != nil {
		return nil, &InvalidPrometheusHistogramVecNameError{
			name: histogramProvider.Name,
		}
	}

	return histogramProvider, nil
}

// Cancel unregisters the prometheus histogramVec from the prometheus registerer.
func (histogramProvider *Provider) Cancel() error {
	histogramProvider.registry.Unregister(histogramProvider.HistogramVec)
	return nil
}

// With attempts to create a Histogram, which is a wrapper around the prometheus histogram metric that implements the CancellableObservable interface.
func (histogramProvider *Provider) With(
	label string,
) (registry.CancellableObservable, error) {
	histogram, err := histogramProvider.HistogramVec.GetMetricWith(
		prometheus.Labels{histogramProvider.Label: label},
	)
	if err != nil {
		return nil, &InvalidPrometheusHistogramLabelError{
			name:  histogramProvider.Name,
			label: label,
		}
	}

	return NewHistogram(histogram), nil
}

// Histogram is an implementation of the CancellableObservable which wraps the functionality of the prometheus histogram metric.
// It observes a value into the prometheus histogram when its observe function is called.
type Histogram struct {
	observable prometheus.Observer
}

// NewHistogram creates a histogram given a prometheus histogram (in the form of an observable interface).
func NewHistogram(observable prometheus.Observer) *Histogram {
	return &Histogram{
		observable: observable,
	}
}

// Observer calls the prometheus histograms observe function to observe a new value into the histogram.
func (histogram Histogram) Observe(value float64) {
	histogram.observable.Observe(value)
}

// Cancel is a no-op because a prometheus observable cannot be unregistered.
func (histogram Histogram) Cancel() {}
