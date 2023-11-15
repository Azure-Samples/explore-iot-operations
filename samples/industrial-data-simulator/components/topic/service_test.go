// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package topic

import (
	"testing"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID         = "MockID"
	MockRegistryID = "MockRegistryID"
	MockTopic      = "MockTopic"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Renderer, component.ID])
	require.True(t, ok)
}

func TestTopicService(t *testing.T) {
	service := NewService(&component.MockStore[Renderer, component.ID]{
		OnCreate: func(entity Renderer, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockTopic, entity.Render())
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		Name:       MockTopic,
		RegistryID: MockRegistryID,
	})
	require.NoError(t, err)
}

func TestTopicServiceNoopRegistry(t *testing.T) {
	service := NewService(&component.MockStore[Renderer, component.ID]{
		OnCreate: func(entity Renderer, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockTopic, entity.Render())
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, &component.NotFoundError{}
		},
	})

	err := service.Create(MockID, &Component{
		Name:       MockTopic,
		RegistryID: MockRegistryID,
	})
	require.NoError(t, err)
}

func TestTopicServiceRegistryError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, &component.MockError{}
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}
