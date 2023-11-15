// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package broker

import (
	"testing"

	"github.com/stretchr/testify/require"
)

const (
	MockID         = "MockID"
	MockRegistryID = "MockRegistryID"
	MockHost       = "localhost"
	MockPort       = 4000
	MockEndpoint   = "localhost:4000"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestCounterProviderWithInvalidName(t *testing.T) {
	expected := MockEndpoint

	broker := New(nil, func(b *Broker) {
		b.Broker = MockHost
		b.Port = MockPort
	})

	require.Equal(t, expected, broker.Endpoint())
}
