// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package registry

import (
	"testing"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
	"github.com/stretchr/testify/require"
)

const MockID = "MockID"

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[ObservableRegistry, component.ID])
	require.True(t, ok)
}

func TestService(t *testing.T) {
	service := NewService(
		&component.MockStore[ObservableRegistry, component.ID]{
			OnCreate: func(entity ObservableRegistry, identifier component.ID) error {
				require.Equal(t, MockID, string(identifier))
				return nil
			},
		},
	)

	require.NoError(t, service.Create(MockID, nil))
}
