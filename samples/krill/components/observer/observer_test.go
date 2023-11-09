package observer

import (
	"testing"

	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestMockObserver(t *testing.T) {
	expected := 101.0
	cancelled := make(chan struct{})
	obs := &MockObserver{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
		}, OnCancel: func() {
			close(cancelled)
		},
	}

	obs.Observe(expected)
	go obs.Cancel()
	<-cancelled
}

func TestBasicRegistryAndObserver(t *testing.T) {

	expected := 101.0
	reg := registry.NewRegistry()
	cancelled := make(chan struct{})
	observed := make(chan struct{})
	obs := NewObserver(&MockObserver{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
			close(observed)
		}, OnCancel: func() {
			close(cancelled)
		},
	}, reg)

	go reg.Observe(expected)
	<-observed
	go obs.Cancel()
	<-cancelled
}

func TestRegistryWithMultipleObservables(t *testing.T) {
	expected := 101.0
	reg := registry.NewRegistry()
	cancelled := make(chan struct{})
	observed := make(chan struct{})
	obsOne := NewObserver(&MockObserver{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
			observed <- struct{}{}
		}, OnCancel: func() {
			close(cancelled)
		},
	}, reg)
	NewObserver(&MockObserver{
		OnObserve: func(val float64) {
			require.Equal(t, expected, val)
			observed <- struct{}{}
		},
	}, reg)

	go reg.Observe(expected)
	<-observed
	<-observed
	close(observed)

	go obsOne.Cancel()
	<-cancelled
}