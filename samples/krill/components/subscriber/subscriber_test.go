// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package subscriber

import (
	"testing"

	"github.com/explore-iot-ops/samples/krill/components/client"
	"github.com/explore-iot-ops/samples/krill/components/outlet"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/components/topic"
	"github.com/explore-iot-ops/samples/krill/components/tracer"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestSubscribeAfterClientConnection(t *testing.T) {
	onSub := make(chan struct{})
	cli := &client.MockClient{
		OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
			close(onSub)
			return nil
		}, OnUnsubscribe: func(topic string) error {
			return nil
		}, OnDisconnect: make(chan struct{}),
		OnConnect: make(chan struct{}),
	}
	sub := New(
		cli,
		topic.New(nil),
		&outlet.NoopOutlet{},
		&registry.NoopRegistry{},
		tracer.NewNoopTracer(),
	)
	go func() {
		err := sub.Start()
		require.NoError(t, err)
	}()
	err := cli.Connect()
	require.NoError(t, err)
	<-onSub
}

func TestReceivedChannelWithBlocking(t *testing.T) {
	onSub := make(chan struct{})
	cli := &client.MockClient{
		OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
			close(onSub)
			onReceived(nil)
			return nil
		}, OnUnsubscribe: func(topic string) error {
			return nil
		}, OnDisconnect: make(chan struct{}),
		OnConnect: make(chan struct{}),
	}
	sub := New(
		cli,
		topic.New(nil),
		&outlet.NoopOutlet{},
		&registry.NoopRegistry{},
		tracer.NewNoopTracer(),
		func(s *Subscriber) {},
	)
	go func() {
		err := sub.Start()
		require.NoError(t, err)
	}()
	err := cli.Connect()
	require.NoError(t, err)
	<-onSub
}

func TestReceivedChannelWithoutBlocking(t *testing.T) {
	onSub := make(chan struct{})
	afterOnReceivedCalled := make(chan struct{})
	cli := &client.MockClient{
		OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
			close(onSub)
			onReceived(nil)
			close(afterOnReceivedCalled)
			return nil
		}, OnUnsubscribe: func(topic string) error {
			return nil
		}, OnDisconnect: make(chan struct{}),
		OnConnect: make(chan struct{}),
	}
	sub := New(
		cli,
		topic.New(nil),
		&outlet.NoopOutlet{},
		&registry.NoopRegistry{},
		tracer.NewNoopTracer(),
	)
	go func() {
		err := sub.Start()
		require.NoError(t, err)
	}()
	err := cli.Connect()
	require.NoError(t, err)
	<-onSub
	<-afterOnReceivedCalled
}

func TestSubscriberCancelBeforeClientCancel(t *testing.T) {
	onSub := make(chan struct{})
	onUnsub := make(chan struct{})

	cli := &client.MockClient{
		OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
			close(onSub)
			return nil
		}, OnUnsubscribe: func(topic string) error {
			close(onUnsub)
			return nil
		}, OnDisconnect: make(chan struct{}),
		OnConnect: make(chan struct{}),
	}
	sub := New(
		cli,
		topic.New(nil),
		&outlet.NoopOutlet{},
		&registry.NoopRegistry{},
		tracer.NewNoopTracer(),
	)
	go func() {
		require.NoError(t, sub.Start())
	}()
	err := cli.Connect()
	require.NoError(t, err)
	<-onSub
	err = sub.Cancel()
	require.NoError(t, err)
	<-onUnsub
}

func TestSubscriberCancelAfterClientCancel(t *testing.T) {
	onSub := make(chan struct{})
	onDisconnect := make(chan struct{})
	name := "name"

	cli := &client.MockClient{
		OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
			close(onSub)
			return nil
		}, OnUnsubscribe: func(topic string) error {
			return nil
		}, OnDisconnect: onDisconnect,
		OnConnect: make(chan struct{}),
		OnGetName: func() string {
			return name
		},
	}
	sub := New(
		cli,
		topic.New(nil),
		&outlet.NoopOutlet{},
		&registry.NoopRegistry{},
		tracer.NewNoopTracer(),
	)
	go func() {
		require.NoError(t, sub.Start())
	}()
	err := cli.Connect()
	require.NoError(t, err)
	<-onSub
	go func() {
		err := cli.Disconnect()
		require.NoError(t, err)
	}()
	<-onDisconnect
	err = sub.Cancel()
	require.Equal(t, ClientConnectionClosedError{
		client: name,
	}, *err.(*ClientConnectionClosedError))
}
