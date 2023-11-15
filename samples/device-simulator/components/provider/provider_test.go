// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package provider

import (
	"testing"

	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestMockProvider(t *testing.T) {
	expected := "label"
	cancelled := make(chan struct{})
	mock := &MockProvider{
		OnWith: func(label string) (registry.CancellableObservable, error) {
			require.Equal(t, expected, label)
			return nil, nil
		}, OnCancel: func() error {
			go close(cancelled)
			return nil
		},
	}
	_, err := mock.With(expected)
	require.NoError(t, err)
	err = mock.Cancel()
	require.NoError(t, err)
	<-cancelled
}
