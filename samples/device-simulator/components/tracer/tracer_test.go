// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package tracer

import (
	"testing"
	"time"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestBlockingTracer(t *testing.T) {
	waitMs := 5
	done := make(chan struct{}, 1)
	tracer := New(&registry.MockObservable{
		OnObserve: func(val float64) {
			// Ensure we were blocked for at least waitMs.
			require.GreaterOrEqual(t, int(val), waitMs)
			done <- struct{}{}
		},
	}, func(bt *BlockingTracer) {
		bt.Logger = &logger.NoopLogger{}
	})

	first := tracer.Begin()
	go func() {
		<-first
		done <- struct{}{}
	}()
	// Block for several milliseconds
	<-time.After(time.Millisecond * time.Duration(waitMs))
	tracer.Received()

	<-done
	<-done
}

func TestNoopTracer(t *testing.T) {
	tracer := NewNoopTracer()
	tracer.Received()
	<-tracer.Begin()
}
