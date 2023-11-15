// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package publisher provides the implementation for the publisher component of the simulation framework along with all associated interfaces.
package publisher

import (
	"context"
	"time"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/components/client"
	"github.com/explore-iot-ops/samples/krill/components/limiter"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/components/renderer"
	"github.com/explore-iot-ops/samples/krill/components/topic"
	"github.com/explore-iot-ops/samples/krill/components/tracer"
	"github.com/explore-iot-ops/samples/krill/lib/environment"
)

// Publisher is a component which routinely publishes messages on a provided topic name.
// It uses a work pool to publish messages.
type Publisher struct {
	ctx               context.Context
	tracer            tracer.Tracer
	client            client.Publisher
	renderer          renderer.Renderer
	topic             topic.Renderer
	monitor           registry.Observable
	env               environment.Environment
	Cancel            context.CancelFunc
	limiter           limiter.Limiter[struct{}]
	Logger            logger.Logger
	QoS               int
	RendersPerPublish int
	MessagesRetained  bool
	Name              string
	Site              string
}

// New creates a Publisher given a context, a work pool of type PublishResult,
// a payload to render MQTT message bodies from, a client whose connection will be used to publish messages,
// a topic to render MQTT topic to publish on, and a monitor to observe message publishing latencies with.
// Optional parameters can be set with the options function.
func New(
	ctx context.Context,
	ren renderer.Renderer,
	cli client.Publisher,
	top topic.Renderer,
	env environment.Environment,
	mon registry.Observable,
	tra tracer.Tracer,
	lim limiter.Limiter[struct{}],
	options ...func(*Publisher),
) *Publisher {
	publisher := &Publisher{
		client:            cli,
		topic:             top,
		renderer:          ren,
		ctx:               ctx,
		monitor:           mon,
		env:               env,
		limiter:           lim,
		tracer:            tra,
		Logger:            &logger.NoopLogger{},
		RendersPerPublish: 1,
	}

	for _, option := range options {
		option(publisher)
	}

	publisher.env.Set("x", -1)
	publisher.env.Set("start", time.Now())
	publisher.env.Set("site", publisher.Site)
	publisher.env.Set("id", publisher.Name)

	ctx, cancel := context.WithCancel(publisher.ctx)
	publisher.Cancel = cancel
	publisher.ctx = ctx

	return publisher
}

func (publisher *Publisher) publish(ctx context.Context) error {

	data, err := publisher.renderer.Render(
		publisher.env,
		publisher.env.Env()["x"].(int)+1,
		publisher.RendersPerPublish,
	)
	if err != nil {
		return err
	}

	start := time.Now()

	res := make(chan error)
	block := publisher.tracer.Begin()
	go func() {
		res <- publisher.client.Publish(
			publisher.topic.Render(),
			byte(publisher.QoS),
			publisher.MessagesRetained,
			data,
		)
	}()

	select {
	case <-ctx.Done():
		return nil
	case err := <-res:
		acknowledgementLatency := time.Since(start)

		publisher.monitor.Observe(
			float64(acknowledgementLatency.Milliseconds()),
		)
		publisher.topic.Observe(float64(acknowledgementLatency.Milliseconds()))
		publisher.client.Observe(float64(acknowledgementLatency.Milliseconds()))

		<-block

		return err
	}
}

// Start will begin the operation of the publisher, only starting to send messages once the underlying client is successfully connected to an MQTT broker.
// It will return if its context is cancelled, or if the underlying client is disconnected.
func (publisher *Publisher) Start() {
	<-publisher.client.Connected()
	input := publisher.limiter.Input()
	output := publisher.limiter.Output()

	errorLvl := publisher.Logger.Level(logger.Error)

	for {
		select {
		case <-publisher.ctx.Done():
			return
		case <-publisher.client.Disconnected():
			return
		case input <- struct{}{}:
		case <-output:
			err := publisher.publish(publisher.ctx)
			if err != nil {
				errorLvl.With("error", err.Error()).
					Printf("error publishing message")
			}
		}
	}
}
