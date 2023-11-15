// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package limiter

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestLimiter(t *testing.T) {

	ctx := context.Background()

	expectedMinimumDurationMs := 4
	reqsPerSecond := 1000

	limiter := &TimedLimiter[struct{}]{
		Limit:  reqsPerSecond,
		Period: time.Duration(expectedMinimumDurationMs) * time.Millisecond,
		input:  make(chan struct{}),
		output: make(chan struct{}),
	}

	go limiter.Start(ctx)

	done := make(chan struct{})

	var elapsed time.Duration

	go func() {
		start := time.Now()
		for count := 0; count < (expectedMinimumDurationMs+1)*reqsPerSecond; count++ {
			limiter.Input() <- struct{}{}
			<-limiter.Output()
		}
		elapsed = time.Since(start)
		close(done)
	}()

	<-done

	require.LessOrEqual(
		t,
		time.Millisecond*time.Duration(expectedMinimumDurationMs),
		elapsed,
	)
}

func TestLimiterCancellation(t *testing.T) {

	ctx, cancel := context.WithCancel(context.Background())

	// Enforce extremely slow rate limiting.
	limiter := &TimedLimiter[struct{}]{
		Limit:  1,
		Period: time.Hour,
		input:  make(chan struct{}),
		output: make(chan struct{}),
	}

	go limiter.Start(ctx)

	done := make(chan struct{})

	go func() {
		for count := 0; count < 1000; count++ {
			limiter.Input() <- struct{}{}
			<-limiter.Output()
		}
		close(done)
	}()

	cancel()
	<-limiter.Output()
}
