package outlet

import (
	"testing"

	"github.com/explore-iot-ops/samples/krill/components/formatter"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID            = "MockID"
	MockRegistryID    = "MockRegistryID"
	MockFormatterID   = "MockFormatterID"
	MockConfiguration = "MockConfiguration"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Outlet, component.ID])
	require.True(t, ok)
}

func TestService(t *testing.T) {
	service := NewService(&component.MockStore[Outlet, component.ID]{
		OnCreate: func(entity Outlet, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			_, ok := entity.(*PrometheusOutlet)
			require.True(t, ok)
			return nil
		},
	}, &component.MockStore[formatter.Formatter, component.ID]{
		OnGet: func(identifier component.ID) (formatter.Formatter, error) {
			require.Equal(t, MockFormatterID, string(identifier))
			return nil, nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		RegistryID:    MockRegistryID,
		FormatterID:   MockFormatterID,
		Configuration: "MockConfiguration",
	})
	require.NoError(t, err)
}

func TestServiceFormatterError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[formatter.Formatter, component.ID]{
			OnGet: func(identifier component.ID) (formatter.Formatter, error) {
				return nil, &component.MockError{}
			},
		},
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}

func TestServiceRegistryError(t *testing.T) {
	service := NewService(
		nil,
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

func TestServiceParserError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[formatter.Formatter, component.ID]{
			OnGet: func(identifier component.ID) (formatter.Formatter, error) {
				return nil, nil
			},
		},
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Error(t, err)
}
