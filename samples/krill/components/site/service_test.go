package site

import (
	"testing"

	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID         = "MockID"
	MockRegistryID = "MockRegistryID"
	MockSiteName   = "MockSiteName"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Site, component.ID])
	require.True(t, ok)
}

func TestSiteService(t *testing.T) {
	service := NewService(&component.MockStore[Site, component.ID]{
		OnCreate: func(entity Site, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockSiteName, entity.Render())
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		Name:       MockSiteName,
		RegistryID: MockRegistryID,
	})
	require.NoError(t, err)
}

func TestSiteServiceRegistryError(t *testing.T) {
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

func TestSiteServiceNoopRegistry(t *testing.T) {
	service := NewService(&component.MockStore[Site, component.ID]{
		OnCreate: func(entity Site, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			require.Equal(t, MockSiteName, entity.Render())
			return nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, &component.NotFoundError{}
		},
	})

	err := service.Create(MockID, &Component{
		Name:       MockSiteName,
		RegistryID: MockRegistryID,
	})
	require.NoError(t, err)
}
