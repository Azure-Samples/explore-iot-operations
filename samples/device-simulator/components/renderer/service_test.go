// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package renderer

import (
	"testing"

	"github.com/explore-iot-ops/samples/device-simulator/components/formatter"
	"github.com/explore-iot-ops/samples/device-simulator/lib/component"
	"github.com/explore-iot-ops/samples/device-simulator/lib/composition"
	"github.com/stretchr/testify/require"
)

const (
	MockID          = "MockID"
	MockFormatterID = "MockFormatterID"
	MockNodeID      = "MockNodeID"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Renderer, component.ID])
	require.True(t, ok)
}

func TestRendererService(t *testing.T) {
	service := NewService(&component.MockStore[Renderer, component.ID]{
		OnCreate: func(entity Renderer, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	}, &component.MockStore[formatter.Formatter, component.ID]{
		OnGet: func(identifier component.ID) (formatter.Formatter, error) {
			require.Equal(t, MockFormatterID, string(identifier))
			return nil, nil
		},
	}, &component.MockStore[composition.Renderer, component.ID]{
		OnGet: func(identifier component.ID) (composition.Renderer, error) {
			require.Equal(t, MockNodeID, string(identifier))
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		FormatterID: MockFormatterID,
		NodeID:      MockNodeID,
	})
	require.NoError(t, err)
}

func TestRendererServiceNodeStoreError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[formatter.Formatter, component.ID]{
			OnGet: func(identifier component.ID) (formatter.Formatter, error) {
				return nil, nil
			},
		},
		&component.MockStore[composition.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (composition.Renderer, error) {
				return nil, &component.MockError{}
			},
		},
	)

	err := service.Create(MockID, &Component{
		FormatterID: MockFormatterID,
		NodeID:      MockNodeID,
	})
	require.Equal(t, &component.MockError{}, err)
}

func TestRendererServiceFormatterStoreError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[formatter.Formatter, component.ID]{
			OnGet: func(identifier component.ID) (formatter.Formatter, error) {
				return nil, &component.MockError{}
			},
		},
		nil,
	)

	err := service.Create(MockID, &Component{
		FormatterID: MockFormatterID,
		NodeID:      MockNodeID,
	})
	require.Equal(t, &component.MockError{}, err)
}
