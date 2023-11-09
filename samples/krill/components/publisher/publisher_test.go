package publisher

import (
	"context"
	"testing"

	"github.com/explore-iot-ops/lib/env"
	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/components/client"
	"github.com/explore-iot-ops/samples/krill/components/formatter"
	"github.com/explore-iot-ops/samples/krill/components/limiter"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/components/renderer"
	"github.com/explore-iot-ops/samples/krill/components/topic"
	"github.com/explore-iot-ops/samples/krill/components/tracer"
	"github.com/explore-iot-ops/samples/krill/lib/composition"
	"github.com/explore-iot-ops/samples/krill/lib/errors"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestPublisher(t *testing.T) {

	ctx := context.Background()

	lim := &limiter.NoopLimiter[struct{}]{
		C: make(chan struct{}, 1),
	}

	reg := registry.NewRegistry()

	ren := renderer.New(composition.NewCollection(), formatter.NewJsonFormatter())

	top := topic.New(reg)

	finished := make(chan struct{})

	cli := &client.MockClient{
		OnConnect: make(chan struct{}),
		OnPublish: func(topic string, qos byte, messagesRetained bool, data []byte) error {
			finished <- struct{}{}
			return nil
		}, Observable: reg,
	}
	go close(cli.OnConnect)

	env := environment.New()

	publisher := New(ctx, ren, cli, top, env, reg, tracer.NewNoopTracer(), lim, func(p *Publisher) {
		p.QoS = 1
	})
	go publisher.Start()
	<-finished
}

func TestPublisherWithPublishError(t *testing.T) {

	ctx := context.Background()

	lim := &limiter.NoopLimiter[struct{}]{
		C: make(chan struct{}, 1),
	}

	reg := registry.NewRegistry()

	ren := renderer.New(composition.NewCollection(), formatter.NewJsonFormatter())
	top := topic.New(reg)
	cli := &client.MockClient{
		OnConnect: make(chan struct{}),
		OnPublish: func(topic string, qos byte, messagesRetained bool, data []byte) error {
			return errors.Mock{}
		}, Observable: reg,
	}
	go close(cli.OnConnect)

	finished := make(chan struct{})

	lg := &logger.MockLogger{
		OnLevel: func(i int) logger.Logger {
			return &logger.MockLogger{
				OnWith: func(s1, s2 string) logger.Logger {
					require.Equal(t, errors.Mock{}.Error(), s2)
					finished <- struct{}{}
					return &logger.NoopLogger{}
				},
			}
		},
	}

	env := environment.New()

	publisher := New(ctx, ren, cli, top, env, reg, tracer.NewNoopTracer(), lim, func(p *Publisher) {
		p.QoS = 1
		p.Logger = lg
	})
	go publisher.Start()
	<-finished
}

func TestPublisherDisconnectViaClientDisconnect(t *testing.T) {

	ctx := context.Background()
	lim := &limiter.NoopLimiter[struct{}]{
		C: make(chan struct{}, 1),
	}
	reg := registry.NewRegistry()
	ren := renderer.New(composition.NewCollection(), formatter.NewJsonFormatter())
	top := topic.New(reg)
	cli := &client.MockClient{
		OnConnect:    make(chan struct{}),
		OnDisconnect: make(chan struct{}),
		Observable:   reg,
		OnPublish: func(topic string, qos byte, messagesRetained bool, data []byte) error {
			return nil
		},
	}
	go close(cli.OnConnect)

	env := environment.New()

	publisher := New(ctx, ren, cli, top, env, reg, tracer.NewNoopTracer(), lim)

	go close(cli.OnDisconnect)
	publisher.Start()
}

func TestPublisherDisconnectViaCancellation(t *testing.T) {

	ctx := context.Background()
	lim := &limiter.NoopLimiter[struct{}]{
		C: make(chan struct{}, 1),
	}
	reg := registry.NewRegistry()
	ren := renderer.New(composition.NewCollection(), formatter.NewJsonFormatter())
	top := topic.New(reg)
	cli := &client.MockClient{
		OnConnect:    make(chan struct{}),
		OnDisconnect: make(chan struct{}),
		Observable:   reg,
		OnPublish: func(topic string, qos byte, messagesRetained bool, data []byte) error {
			return nil
		},
	}
	go close(cli.OnConnect)

	env := environment.New()

	publisher := New(ctx, ren, cli, top, env, reg, tracer.NewNoopTracer(), lim)

	go publisher.Cancel()
	publisher.Start()
}
