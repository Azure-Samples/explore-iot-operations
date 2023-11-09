package gauge

import (
	"fmt"

	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/lib/errors"
	"github.com/prometheus/client_golang/prometheus"
)

type Provider struct {
	Vec      *prometheus.GaugeVec
	registry prometheus.Registerer
	Name     string
	Help     string
	Label    string
}

const (
	GaugeLabelKey              = "gauge"
	SimulationGaugeDefaultName = "simulation_gauge"
	SimulationGaugeDefaultHelp = "Simulation gauge"
)

type InvalidPrometheusGaugeVecNameError struct {
	errors.BadRequest
	name string
}

func (err *InvalidPrometheusGaugeVecNameError) Error() string {
	return fmt.Sprintf(
		"could not create the gauge provider with the name %s because the name has already been registered or is invalid",
		err.name,
	)
}

type InvalidPrometheusGaugeLabelError struct {
	errors.BadRequest
	name  string
	label string
}

func (err *InvalidPrometheusGaugeLabelError) Error() string {
	return fmt.Sprintf(
		"could not create the prometheus gauge with label %s from gauge provider %s because the label has already been used or is invalid",
		err.label,
		err.name,
	)
}

func New(
	reg prometheus.Registerer,
	options ...func(*Provider),
) (*Provider, error) {
	provider := &Provider{
		registry: reg,
		Label:    GaugeLabelKey,
		Name:     SimulationGaugeDefaultName,
		Help:     SimulationGaugeDefaultHelp,
	}

	for _, option := range options {
		option(provider)
	}

	provider.Vec = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: provider.Name,
			Help: provider.Help,
		},
		[]string{provider.Label},
	)

	err := provider.registry.Register(provider.Vec)

	if err != nil {
		return nil, &InvalidPrometheusGaugeVecNameError{
			name: provider.Name,
		}
	}

	return provider, nil
}

func (provider *Provider) Cancel() error {
	provider.registry.Unregister(provider.Vec)
	return nil
}

func (provider *Provider) With(
	label string,
) (registry.CancellableObservable, error) {

	counter, err := provider.Vec.GetMetricWith(
		prometheus.Labels{provider.Label: label},
	)

	if err != nil {
		return nil, &InvalidPrometheusGaugeLabelError{
			name:  provider.Name,
			label: label,
		}
	}

	return NewGauge(provider.registry, counter), nil
}

type Gauge struct {
	observable prometheus.Gauge
	registry   prometheus.Registerer
}

func NewGauge(
	reg prometheus.Registerer,
	observable prometheus.Gauge,
) *Gauge {
	return &Gauge{
		registry:   reg,
		observable: observable,
	}
}

func (gauge Gauge) Cancel() {
	gauge.registry.Unregister(gauge.observable)
}

func (gauge Gauge) Observe(f float64) {
	gauge.observable.Set(f)
}
