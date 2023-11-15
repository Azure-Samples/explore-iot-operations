// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package subscriber

import (
	"testing"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/client"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/outlet"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/topic"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/tracer"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID         = "MockID"
	MockClientID   = "MockClientID"
	MockTopicID    = "MockTopicID"
	MockOutletID   = "MockOutletID"
	MockRegistryID = "MockRegistryID"
	MockTracerID   = "MockTracerID"
	MockName       = "MockName"
	MockTopic      = "MockTopic"
	MockSiteName   = "MockSiteName"
	MockQoSLevel   = 1
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[*Subscriber, component.ID])
	require.True(t, ok)
}

func TestService(t *testing.T) {
	service := NewService(&component.MockStore[*Subscriber, component.ID]{
		OnCreate: func(entity *Subscriber, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	}, &component.MockStore[client.PublisherSubscriber, component.ID]{
		OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
			require.Equal(t, MockClientID, string(identifier))
			return &MockClient{
				PublisherSubscriber: &client.MockClient{
					OnGetName: func() string {
						return MockName
					}, OnRender: func() string {
						return MockSiteName
					}, OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
						require.Equal(t, MockTopic, topic)
						require.Equal(t, byte(MockQoSLevel), qos)
						return nil
					},
				}, OnConnected: func() chan struct{} {
					c := make(chan struct{})
					close(c)
					return c
				}, OnDisconnected: func() chan struct{} {
					c := make(chan struct{})
					close(c)
					return c
				},
			}, nil
		},
	}, &component.MockStore[topic.Renderer, component.ID]{
		OnGet: func(identifier component.ID) (topic.Renderer, error) {
			require.Equal(t, MockTopicID, string(identifier))
			return &topic.Topic{
				Topic: MockTopic,
			}, nil
		},
	}, &component.MockStore[outlet.Outlet, component.ID]{
		OnGet: func(identifier component.ID) (outlet.Outlet, error) {
			require.Equal(t, MockOutletID, string(identifier))
			return nil, nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, nil
		},
	}, &component.MockStore[tracer.Tracer, component.ID]{
		OnGet: func(identifier component.ID) (tracer.Tracer, error) {
			require.Equal(t, MockTracerID, string(identifier))
			return nil, nil
		},
	}, func(s *Service) {
		s.Logger = &logger.NoopLogger{}
	})

	err := service.Create(MockID, &Component{
		ClientID:   MockClientID,
		TopicID:    MockTopicID,
		OutletID:   MockOutletID,
		RegistryID: MockRegistryID,
		TracerID:   MockTracerID,
		QoSLevel:   MockQoSLevel,
	})

	require.NoError(t, err)
}

func TestServiceSubscriptionError(t *testing.T) {
	service := NewService(&component.MockStore[*Subscriber, component.ID]{
		OnCreate: func(entity *Subscriber, identifier component.ID) error {
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	}, &component.MockStore[client.PublisherSubscriber, component.ID]{
		OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
			require.Equal(t, MockClientID, string(identifier))
			return &MockClient{
				PublisherSubscriber: &client.MockClient{
					OnGetName: func() string {
						return MockName
					}, OnRender: func() string {
						return MockSiteName
					}, OnSubscribe: func(topic string, qos byte, onReceived func([]byte)) error {
						return &component.MockError{}
					},
				}, OnConnected: func() chan struct{} {
					c := make(chan struct{})
					close(c)
					return c
				}, OnDisconnected: func() chan struct{} {
					c := make(chan struct{})
					close(c)
					return c
				},
			}, nil
		},
	}, &component.MockStore[topic.Renderer, component.ID]{
		OnGet: func(identifier component.ID) (topic.Renderer, error) {
			require.Equal(t, MockTopicID, string(identifier))
			return &topic.Topic{
				Topic: MockTopic,
			}, nil
		},
	}, &component.MockStore[outlet.Outlet, component.ID]{
		OnGet: func(identifier component.ID) (outlet.Outlet, error) {
			require.Equal(t, MockOutletID, string(identifier))
			return nil, nil
		},
	}, &component.MockStore[registry.ObservableRegistry, component.ID]{
		OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
			require.Equal(t, MockRegistryID, string(identifier))
			return nil, nil
		},
	}, &component.MockStore[tracer.Tracer, component.ID]{
		OnGet: func(identifier component.ID) (tracer.Tracer, error) {
			require.Equal(t, MockTracerID, string(identifier))
			return nil, nil
		},
	})

	err := service.Create(MockID, &Component{
		ClientID:   MockClientID,
		TopicID:    MockTopicID,
		OutletID:   MockOutletID,
		RegistryID: MockRegistryID,
		TracerID:   MockTracerID,
		QoSLevel:   MockQoSLevel,
	})

	require.Equal(t, &component.MockError{}, err)
}

func TestServiceTopicStoreError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[client.PublisherSubscriber, component.ID]{
			OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
				return nil, nil
			},
		},
		&component.MockStore[topic.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (topic.Renderer, error) {
				return nil, &component.MockError{}
			},
		},
		&component.MockStore[outlet.Outlet, component.ID]{
			OnGet: func(identifier component.ID) (outlet.Outlet, error) {
				return nil, nil
			},
		},
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				return nil, nil
			},
		},
	)

	err := service.Create(MockID, &Component{})

	require.Equal(t, &component.MockError{}, err)
}

func TestServiceClientStoreError(t *testing.T) {
	service := NewService(
		nil,
		&component.MockStore[client.PublisherSubscriber, component.ID]{
			OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
				return nil, &component.MockError{}
			},
		},
		nil,
		&component.MockStore[outlet.Outlet, component.ID]{
			OnGet: func(identifier component.ID) (outlet.Outlet, error) {
				return nil, &component.NotFoundError{}
			},
		},
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, &component.NotFoundError{}
			},
		},
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				return nil, &component.NotFoundError{}
			},
		},
	)

	err := service.Create(MockID, &Component{})

	require.Equal(t, &component.MockError{}, err)
}

func TestServiceOutletStoreError(t *testing.T) {
	service := NewService(
		nil,
		nil,
		nil,
		&component.MockStore[outlet.Outlet, component.ID]{
			OnGet: func(identifier component.ID) (outlet.Outlet, error) {
				return nil, &component.MockError{}
			},
		},
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				return nil, nil
			},
		},
	)

	err := service.Create(MockID, &Component{})

	require.Equal(t, &component.MockError{}, err)
}

func TestServiceTracerStoreError(t *testing.T) {
	service := NewService(
		nil,
		nil,
		nil,
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				return nil, &component.MockError{}
			},
		},
	)

	err := service.Create(MockID, &Component{})

	require.Equal(t, &component.MockError{}, err)
}

func TestServiceRegistryStoreError(t *testing.T) {
	service := NewService(
		nil,
		nil,
		nil,
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, &component.MockError{}
			},
		},
		nil,
	)

	err := service.Create(MockID, &Component{})

	require.Equal(t, &component.MockError{}, err)
}
