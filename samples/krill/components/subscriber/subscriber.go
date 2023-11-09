// Package subscriber provides the implementation for the subscriber component of the simulation framework.
package subscriber

import (
	"fmt"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/components/client"
	"github.com/explore-iot-ops/samples/krill/components/outlet"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/components/topic"
	"github.com/explore-iot-ops/samples/krill/components/tracer"
)

type ClientConnectionClosedError struct {
	client string
}

func (err *ClientConnectionClosedError) Error() string {
	return fmt.Sprintf(
		"the connection of client with id %s was already closed before unsubscribing",
		err.client,
	)
}

// Subscriber is a component which listens for incoming messages on an MQTT broker whose connection
// is provided by the underlying client component.
type Subscriber struct {
	client    client.PublisherSubscriber
	topic     topic.Renderer
	tracer    tracer.Tracer
	outlet    outlet.Outlet
	monitor   registry.Observable
	Logger    logger.Logger
	onReceive func([]byte)
	QoS       int
}

// New creates a Subscriber, given a client and topic component.
// Optional parameters can be set using the options function.
func New(
	cli client.PublisherSubscriber,
	top topic.Renderer,
	out outlet.Outlet,
	mon registry.Observable,
	tra tracer.Tracer,
	options ...func(*Subscriber),
) *Subscriber {

	subscriber := &Subscriber{
		client:  cli,
		topic:   top,
		outlet:  out,
		monitor: mon,
		tracer:  tra,
		Logger:  &logger.NoopLogger{},
		QoS:     0,
	}

	for _, option := range options {
		option(subscriber)
	}

	errLvl := subscriber.Logger.Level(logger.Error)
	traceLvl := subscriber.Logger.Level(logger.Trace)

	subscriber.onReceive = func(b []byte) {
		traceLvl.Printf("received new message")
		subscriber.monitor.Observe(0)
		err := subscriber.outlet.Observe(b)
		if err != nil {
			errLvl.With("error", err.Error()).
				Printf("error occurred when observing received message")
		}
		subscriber.tracer.Received()
	}

	return subscriber
}

// Start will wait until the underlying client is connected, and then subscribe to the originally provided topic once connected.
func (subscriber *Subscriber) Start() error {
	<-subscriber.client.Connected()
	return subscriber.client.Subscribe(
		subscriber.topic.Render(),
		byte(subscriber.QoS),
		subscriber.onReceive,
	)
}

// Cancel will return an error if the client is already disconnected, and will attempt to unsubscribe if not.
func (subscriber *Subscriber) Cancel() error {
	select {
	case <-subscriber.client.Disconnected():
		return &ClientConnectionClosedError{
			client: subscriber.client.GetName(),
		}
	default:
		return subscriber.client.Unsubscribe(subscriber.topic.Render())
	}
}

type MockClient struct {
	client.PublisherSubscriber
	OnConnected    func() chan struct{}
	OnDisconnected func() chan struct{}
}

func (client *MockClient) Connected() chan struct{} {
	return client.OnConnected()
}

func (client *MockClient) Disconnected() chan struct{} {
	return client.OnDisconnected()
}
