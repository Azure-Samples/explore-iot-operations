package provider

import (
	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/explore-iot-ops/samples/krill/lib/counter"
	"github.com/explore-iot-ops/samples/krill/lib/exporter"
	"github.com/explore-iot-ops/samples/krill/lib/gauge"
	"github.com/explore-iot-ops/samples/krill/lib/histogram"
	"github.com/prometheus/client_golang/prometheus"
)

type Store component.Store[Provider, component.ID]

type Type string

const (
	COUNTER          Type = "counter"
	HISTOGRAM        Type = "histogram"
	GAUGE            Type = "gauge"
	CUSTOM_HISTOGRAM Type = "custom_histogram"
)

type Component struct {
	Help    string
	Name    string
	Label   string
	Start   float64
	Width   float64
	Buckets int
	Type    Type
}

type Service struct {
	Store
	registry prometheus.Registerer
	exporter exporter.Exporter
	Logger   logger.Logger
}

func NewStore() Store {
	return component.New[Provider, component.ID]()
}

func NewService(store Store, registry prometheus.Registerer, exp exporter.Exporter, options ...func(*Service)) *Service {
	service := &Service{
		Store:    store,
		registry: registry,
		exporter: exp,
		Logger:   &logger.NoopLogger{},
	}

	for _, option := range options {
		option(service)
	}

	return service
}

func (service *Service) Create(id component.ID, c *Component) error {
	var provider Provider
	var err error
	switch c.Type {
	case COUNTER:
		provider, err = counter.New(
			service.registry,
			func(cp *counter.Provider) {
				cp.Name = c.Name
				cp.Help = c.Help
			},
		)
	case HISTOGRAM:
		provider, err = histogram.New(
			service.registry,
			func(hp *histogram.Provider) {
				hp.Name = c.Name
				hp.Help = c.Help
				hp.Buckets = c.Buckets
				hp.Start = c.Start
				hp.Width = c.Width
			},
		)
	case GAUGE:
		provider, err = gauge.New(
			service.registry,
			func(gp *gauge.Provider) {
				gp.Name = c.Name
				gp.Help = c.Help
			},
		)
	case CUSTOM_HISTOGRAM:
		provider, err = exporter.New(service.exporter, func(chp *exporter.CustomHistogramProvider) {
			chp.Name = c.Name
			chp.Help = c.Help
			chp.Start = int(c.Start)
			chp.Width = int(c.Width)
			chp.Logger = service.Logger
		})
	default:
		return &InvalidTypeError{
			identifier: string(id),
			kind:       string(c.Type),
		}
	}
	if err != nil {
		return err
	}

	return service.Store.Create(provider, id)
}
