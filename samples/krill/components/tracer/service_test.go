package tracer

import (
	"testing"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID         = "MockID"
	MockRegistryID = "MockRegistryID"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Tracer, component.ID])
	require.True(t, ok)
}

func TestTracerService(t *testing.T) {
	service := NewService(&component.MockStore[Tracer, component.ID]{
		OnCreate: func(entity Tracer, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, nil
		},
	}, func(s *Service) {
		s.Logger = &logger.NoopLogger{}
	})

	err := service.Create(MockID, &Component{
		RegistryID: MockRegistryID,
	})
	require.NoError(t, err)
}

func TestTracerServiceNoopRegistry(t *testing.T) {
	service := NewService(&component.MockStore[Tracer, component.ID]{
		OnCreate: func(entity Tracer, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, &component.NotFoundError{}
		},
	}, func(s *Service) {
		s.Logger = &logger.NoopLogger{}
	})

	err := service.Create(MockID, &Component{
		RegistryID: MockRegistryID,
	})
	require.NoError(t, err)
}

func TestTracerServiceRegistryError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, &component.MockError{}
			},
		},
		func(s *Service) {
			s.Logger = &logger.NoopLogger{}
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}
