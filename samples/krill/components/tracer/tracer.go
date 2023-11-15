// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package tracer

import (
	"fmt"
	"time"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/components/registry"
)

type Tracer interface {
	Begin() chan struct{}
	Received()
}

type BlockingTracer struct {
	traces chan struct{}
	times  chan time.Time
	reg    registry.Observable
	Logger logger.Logger
	Trace  logger.Logger
}

func New(
	reg registry.Observable,
	options ...func(*BlockingTracer),
) *BlockingTracer {
	tracer := &BlockingTracer{
		reg:    reg,
		traces: make(chan struct{}),
		times:  make(chan time.Time, 1),
		Logger: &logger.NoopLogger{},
	}

	for _, option := range options {
		option(tracer)
	}

	tracer.Trace = tracer.Logger.Level(logger.Trace)

	return tracer
}

func (tracer *BlockingTracer) Begin() chan struct{} {
	tracer.Trace.Printf("beginning trace")
	tracer.times <- time.Now()
	return tracer.traces
}

func (tracer *BlockingTracer) Received() {
	start := <-tracer.times
	duration := float64(time.Since(start).Milliseconds())
	tracer.Trace.With("duration", fmt.Sprintf("%0.2f", duration)).
		Printf("ending trace")
	tracer.reg.Observe(duration)
	tracer.traces <- struct{}{}
}

type NoopTracer struct {
	c chan struct{}
}

func NewNoopTracer() *NoopTracer {
	c := make(chan struct{})
	close(c)
	return &NoopTracer{
		c: c,
	}
}

func (tracer *NoopTracer) Begin() chan struct{} {
	return tracer.c
}

func (tracer *NoopTracer) Received() {}
