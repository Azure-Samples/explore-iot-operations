package broker

import (
	"testing"

	"github.com/iot-for-all/device-simulation/components/observer"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/lib/component"
	"github.com/stretchr/testify/require"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Source, component.ID])
	require.True(t, ok)
}

func TestService(t *testing.T) {
	service := NewService(&component.MockStore[Source, component.ID]{
		OnCreate: func(entity Source, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockEndpoint, entity.Endpoint())
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return &registry.MockRegistry{}, nil
		},
	})

	err := service.Create(MockID, &Component{
		RegistryID: MockRegistryID,
		Broker:     MockHost,
		Port:       MockPort,
	})
	require.NoError(t, err)
}

func TestOptionalRegistry(t *testing.T) {
	service := NewService(&component.MockStore[Source, component.ID]{
		OnCreate: func(entity Source, identifier component.ID) error {
			brkr, ok := entity.(*Broker)
			require.True(t, ok)
			require.Equal(t, &observer.NoopObservable{}, brkr.Observable)
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return nil, &component.NotFoundError{}
		},
	})

	err := service.Create(MockID, &Component{})
	require.NoError(t, err)
}

func TestRegistryError(t *testing.T) {
	service := NewService(&component.MockStore[Source, component.ID]{
		OnCreate: func(entity Source, identifier component.ID) error {
			brkr, ok := entity.(*Broker)
			require.True(t, ok)
			require.Equal(t, &observer.NoopObservable{}, brkr.Observable)
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			return nil, &component.MockError{}
		},
	})

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}
