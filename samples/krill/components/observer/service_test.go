// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package observer

import (
	"testing"

	"github.com/explore-iot-ops/samples/krill/components/provider"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID         = "MockID"
	MockObserverID = 1
	MockLabel      = "MockLabel"
	MockRegistryID = "MockRegistryID"
	MockProviderID = "MockProviderID"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[*Observer, component.ID])
	require.True(t, ok)
}

func TestObserverService(t *testing.T) {
	service := NewService(&component.MockStore[*Observer, component.ID]{
		OnCreate: func(entity *Observer, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			_, ok := entity.registry.(*registry.MockRegistry)
			require.True(t, ok)
			_, ok = entity.observable.(*registry.MockObservable)
			require.True(t, ok)
			require.Equal(t, MockObserverID, entity.ID)
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return &registry.MockRegistry{
				OnRegister: func(o registry.Observable) int {
					res, ok := o.(*Observer)
					require.True(t, ok)
					_, ok = res.registry.(*registry.MockRegistry)
					require.True(t, ok)
					_, ok = res.observable.(*registry.MockObservable)
					require.True(t, ok)

					return MockObserverID
				},
			}, nil
		},
	}, &component.MockStore[provider.Provider, component.ID]{
		OnGet: func(identifier component.ID) (provider.Provider, error) {
			require.Equal(t, MockProviderID, string(identifier))
			return &provider.MockProvider{
				OnWith: func(label string) (registry.CancellableObservable, error) {
					require.Equal(t, MockLabel, label)
					return &registry.MockObservable{}, nil
				},
			}, nil
		},
	})

	err := service.Create(MockID, &Component{
		RegistryID: MockRegistryID,
		ProviderID: MockProviderID,
		Label:      MockLabel,
	})
	require.NoError(t, err)
}

func TestObserverServiceRegistryStoreError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, &component.MockError{}
			},
		},
		nil,
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}

func TestObserverServiceProviderStoreError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		&component.MockStore[provider.Provider, component.ID]{
			OnGet: func(identifier component.ID) (provider.Provider, error) {
				return nil, &component.MockError{}
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}

func TestObserverServiceProviderWithError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		&component.MockStore[provider.Provider, component.ID]{
			OnGet: func(identifier component.ID) (provider.Provider, error) {
				return &provider.MockProvider{
					OnWith: func(label string) (registry.CancellableObservable, error) {
						return nil, &component.MockError{}
					},
				}, nil
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}
