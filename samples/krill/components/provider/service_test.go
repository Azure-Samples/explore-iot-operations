package provider

import (
	"testing"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/explore-iot-ops/samples/krill/lib/counter"
	"github.com/explore-iot-ops/samples/krill/lib/exporter"
	"github.com/explore-iot-ops/samples/krill/lib/gauge"
	"github.com/explore-iot-ops/samples/krill/lib/histogram"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/stretchr/testify/require"
)

const (
	MockID          = "MockID"
	MockHelp        = "MockHelp"
	MockName        = "MockName"
	MockLabel       = "MockLabel"
	MockInvalidType = "MockInvalidType"
	MockStart       = 1.0
	MockWidth       = 10.0
	MockBuckets     = 11
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Provider, component.ID])
	require.True(t, ok)
}

func TestProviderServiceCounter(t *testing.T) {
	service := NewService(&component.MockStore[Provider, component.ID]{
		OnCreate: func(entity Provider, identifier component.ID) error {
			res, ok := entity.(*counter.Provider)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockHelp, res.Help)
			require.Equal(t, MockName, res.Name)
			return nil
		},
	}, &MockRegistry{
		OnRegister: func(c prometheus.Collector) error {
			return nil
		},
	}, &exporter.MockExporter{
		OnRegisterHistogram: func(name, help string, start, width int) (exporter.Provider, error) {
			return nil, nil
		},
	}, func(s *Service) {
		s.Logger = &logger.NoopLogger{}
	})

	err := service.Create(MockID, &Component{
		Help:    MockHelp,
		Name:    MockName,
		Label:   MockLabel,
		Start:   MockStart,
		Width:   MockWidth,
		Buckets: MockBuckets,
		Type:    COUNTER,
	})
	require.NoError(t, err)
}

func TestProviderServiceHistogram(t *testing.T) {
	service := NewService(&component.MockStore[Provider, component.ID]{
		OnCreate: func(entity Provider, identifier component.ID) error {
			res, ok := entity.(*histogram.Provider)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockHelp, res.Help)
			require.Equal(t, MockName, res.Name)
			require.Equal(t, MockBuckets, res.Buckets)
			require.Equal(t, MockStart, res.Start)
			require.Equal(t, MockWidth, res.Width)
			return nil
		},
	}, &MockRegistry{
		OnRegister: func(c prometheus.Collector) error {
			return nil
		},
	}, nil)

	err := service.Create(MockID, &Component{
		Help:    MockHelp,
		Name:    MockName,
		Label:   MockLabel,
		Start:   MockStart,
		Width:   MockWidth,
		Buckets: MockBuckets,
		Type:    HISTOGRAM,
	})
	require.NoError(t, err)
}

func TestProviderServiceGauge(t *testing.T) {
	service := NewService(&component.MockStore[Provider, component.ID]{
		OnCreate: func(entity Provider, identifier component.ID) error {
			res, ok := entity.(*gauge.Provider)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockHelp, res.Help)
			require.Equal(t, MockName, res.Name)
			return nil
		},
	}, &MockRegistry{
		OnRegister: func(c prometheus.Collector) error {
			return nil
		},
	}, nil)

	err := service.Create(MockID, &Component{
		Help:  MockHelp,
		Name:  MockName,
		Label: MockLabel,
		Type:  GAUGE,
	})
	require.NoError(t, err)
}

func TestProviderServiceCustomHistogram(t *testing.T) {
	service := NewService(&component.MockStore[Provider, component.ID]{
		OnCreate: func(entity Provider, identifier component.ID) error {
			res, ok := entity.(*exporter.CustomHistogramProvider)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockHelp, res.Help)
			require.Equal(t, MockName, res.Name)
			require.Equal(t, int(MockStart), res.Start)
			require.Equal(t, int(MockWidth), res.Width)
			return nil
		},
	}, nil, &exporter.MockExporter{
		OnRegisterHistogram: func(name, help string, start, width int) (exporter.Provider, error) {
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		Help:    MockHelp,
		Name:    MockName,
		Label:   MockLabel,
		Start:   MockStart,
		Width:   MockWidth,
		Buckets: MockBuckets,
		Type:    CUSTOM_HISTOGRAM,
	})
	require.NoError(t, err)
}

func TestProviderServiceCustomHistogramError(t *testing.T) {
	service := NewService(&component.MockStore[Provider, component.ID]{
		OnCreate: func(entity Provider, identifier component.ID) error {
			res, ok := entity.(*exporter.CustomHistogramProvider)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockHelp, res.Help)
			require.Equal(t, MockName, res.Name)
			require.Equal(t, int(MockStart), res.Start)
			require.Equal(t, int(MockWidth), res.Width)
			return nil
		},
	}, nil, &exporter.MockExporter{
		OnRegisterHistogram: func(name, help string, start, width int) (exporter.Provider, error) {
			return nil, &component.MockError{}
		},
	})

	err := service.Create(MockID, &Component{
		Help:  MockHelp,
		Name:  MockName,
		Label: MockLabel,
		Start: MockStart,
		Width: MockWidth,
		Type:  CUSTOM_HISTOGRAM,
	})
	require.Equal(t, &component.MockError{}, err)
}

func TestProviderServiceInvalidTypeError(t *testing.T) {
	service := NewService(nil, nil, nil)

	err := service.Create(MockID, &Component{
		Type: MockInvalidType,
	})
	require.Equal(t, &InvalidTypeError{
		identifier: MockID,
		kind:       MockInvalidType,
	}, err)
}
