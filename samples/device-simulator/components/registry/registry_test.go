// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package registry

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestBasicRegistry(t *testing.T) {

	expected := 101.0
	reg := NewRegistry()
	observed := make(chan struct{})
	obs := &MockObservable{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
			close(observed)
		},
	}

	reg.Register(obs)

	go reg.Observe(expected)
	<-observed

	require.Equal(t, 1, len(reg.observables))
}

func TestRegistryWithMultipleObservables(t *testing.T) {
	expected := 101.0
	reg := NewRegistry()
	observed := make(chan struct{})
	obsOne := &MockObservable{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
			observed <- struct{}{}
		},
	}
	obsTwo := &MockObservable{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
			observed <- struct{}{}
		},
	}
	reg.Register(obsOne)
	reg.Register(obsTwo)

	go reg.Observe(expected)
	<-observed
	<-observed
	close(observed)

	require.Equal(t, 2, len(reg.observables))
}
