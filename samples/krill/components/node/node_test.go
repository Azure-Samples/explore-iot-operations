package node

import (
	"testing"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/explore-iot-ops/samples/krill/lib/composition"
	"github.com/stretchr/testify/require"
)

const (
	MockID          = "MockID"
	MockInvalidType = "MockInvalidType"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[composition.Renderer, component.ID])
	require.True(t, ok)
}

func TestServiceExpression(t *testing.T) {
	service := NewService(
		&component.MockStore[composition.Renderer, component.ID]{
			OnCreate: func(entity composition.Renderer, identifier component.ID) error {
				_, ok := entity.(*composition.Expression)
				require.True(t, ok)
				return nil
			},
		},
		func(s *Service) {
			s.Logger = &logger.NoopLogger{}
		},
	)

	err := service.Create(MockID, &Component{
		Type:          EXPRESSION,
		Configuration: "x",
	})
	require.NoError(t, err)
}

func TestServiceCollection(t *testing.T) {
	service := NewService(
		&component.MockStore[composition.Renderer, component.ID]{
			OnCreate: func(entity composition.Renderer, identifier component.ID) error {
				_, ok := entity.(*composition.Collection)
				require.True(t, ok)
				return nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		Type: COLLECTION,
	})
	require.NoError(t, err)
}

func TestServiceArray(t *testing.T) {
	service := NewService(
		&component.MockStore[composition.Renderer, component.ID]{
			OnCreate: func(entity composition.Renderer, identifier component.ID) error {
				_, ok := entity.(*composition.Array)
				require.True(t, ok)
				return nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		Type: ARRAY,
	})
	require.NoError(t, err)
}

func TestServiceTypeError(t *testing.T) {
	service := NewService(
		&component.MockStore[composition.Renderer, component.ID]{
			OnCreate: func(entity composition.Renderer, identifier component.ID) error {
				_, ok := entity.(*composition.Array)
				require.True(t, ok)
				return nil
			},
		},
	)

	err := service.Create(MockID, &Component{
		Type: MockInvalidType,
	})
	require.Equal(t, &InvalidTypeError{
		kind:       MockInvalidType,
		identifier: MockID,
	}, err)
}

func TestServiceExpressionParseError(t *testing.T) {
	service := NewService(nil)

	err := service.Create(MockID, &Component{
		Type:          EXPRESSION,
		Configuration: "",
	})
	require.Error(t, err)
}
