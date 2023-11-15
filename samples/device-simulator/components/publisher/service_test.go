// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package publisher

import (
	"context"
	"testing"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/device-simulator/components/client"
	"github.com/explore-iot-ops/samples/device-simulator/components/limiter"
	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/explore-iot-ops/samples/device-simulator/components/renderer"
	"github.com/explore-iot-ops/samples/device-simulator/components/topic"
	"github.com/explore-iot-ops/samples/device-simulator/components/tracer"
	"github.com/explore-iot-ops/samples/device-simulator/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID                = "MockID"
	MockRegistryID        = "MockRegistryID"
	MockClientID          = "MockClientID"
	MockTopicID           = "MockTopicID"
	MockRendererID        = "MockRendererID"
	MockLimiterID         = "MockLimiterID"
	MockTracerID          = "MockTracerID"
	MockName              = "MockName"
	MockSite              = "MockSite"
	MockQoSLevel          = 1
	MockRendersPerPublish = 1
	MockMessagesRetained  = true
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[*Publisher, component.ID])
	require.True(t, ok)
}

func TestPublisherService(t *testing.T) {
	service := NewService(
		context.Background(),
		&component.MockStore[*Publisher, component.ID]{
			OnCreate: func(entity *Publisher, identifier component.ID) error {
				require.Equal(t, MockName, entity.Name)
				require.Equal(t, MockSite, entity.Site)
				require.Equal(t, MockQoSLevel, entity.QoS)
				require.Equal(
					t,
					MockRendersPerPublish,
					entity.RendersPerPublish,
				)
				require.Equal(t, MockMessagesRetained, entity.MessagesRetained)
				require.Equal(t, MockID, string(identifier))
				return nil
			},
		},
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				require.Equal(t, MockRegistryID, string(identifier))
				return nil, nil
			},
		},
		&component.MockStore[client.PublisherSubscriber, component.ID]{
			OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
				require.Equal(t, MockClientID, string(identifier))
				return &client.MockClient{
					OnGetName: func() string {
						return MockName
					}, OnRender: func() string {
						return MockSite
					},
				}, nil
			},
		},
		&component.MockStore[topic.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (topic.Renderer, error) {
				require.Equal(t, MockTopicID, string(identifier))
				return nil, nil
			},
		},
		&component.MockStore[renderer.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (renderer.Renderer, error) {
				require.Equal(t, MockRendererID, string(identifier))
				return nil, nil
			},
		},
		&component.MockStore[limiter.Limiter[struct{}], component.ID]{
			OnGet: func(identifier component.ID) (limiter.Limiter[struct{}], error) {
				require.Equal(t, MockLimiterID, string(identifier))
				return nil, nil
			},
		},
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				require.Equal(t, MockTracerID, string(identifier))
				return nil, nil
			},
		},
		func(s *Service) {
			s.Logger = &logger.NoopLogger{}
		},
	)

	err := service.Create(MockID, &Component{
		RegistryID:        MockRegistryID,
		ClientID:          MockClientID,
		TopicID:           MockTopicID,
		RendererID:        MockRendererID,
		LimiterID:         MockLimiterID,
		TracerID:          MockTracerID,
		QoSLevel:          MockQoSLevel,
		RendersPerPublish: MockRendersPerPublish,
		MessagesRetained:  MockMessagesRetained,
	})
	require.NoError(t, err)
}

func TestPublisherServiceClientStoreError(t *testing.T) {
	service := NewService(
		context.Background(),
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, &component.NotFoundError{}
			},
		},
		&component.MockStore[client.PublisherSubscriber, component.ID]{
			OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
				return nil, &component.MockError{}
			},
		},
		nil,
		nil,
		nil,
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				return nil, &component.NotFoundError{}
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}

func TestPublisherServiceTopicStoreError(t *testing.T) {
	service := NewService(
		context.Background(),
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
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
		nil,
		nil,
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				return nil, nil
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}

func TestPublisherServiceLimiterStoreError(t *testing.T) {
	service := NewService(
		context.Background(),
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		&component.MockStore[client.PublisherSubscriber, component.ID]{
			OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
				return nil, nil
			},
		},
		&component.MockStore[topic.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (topic.Renderer, error) {
				return nil, nil
			},
		},
		nil,
		&component.MockStore[limiter.Limiter[struct{}], component.ID]{
			OnGet: func(identifier component.ID) (limiter.Limiter[struct{}], error) {
				return nil, &component.MockError{}
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

func TestPublisherServiceRendererStoreError(t *testing.T) {
	service := NewService(
		context.Background(),
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		&component.MockStore[client.PublisherSubscriber, component.ID]{
			OnGet: func(identifier component.ID) (client.PublisherSubscriber, error) {
				return nil, nil
			},
		},
		&component.MockStore[topic.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (topic.Renderer, error) {
				return nil, nil
			},
		},
		&component.MockStore[renderer.Renderer, component.ID]{
			OnGet: func(identifier component.ID) (renderer.Renderer, error) {
				return nil, &component.MockError{}
			},
		},
		&component.MockStore[limiter.Limiter[struct{}], component.ID]{
			OnGet: func(identifier component.ID) (limiter.Limiter[struct{}], error) {
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

func TestPublisherServiceTracerStoreError(t *testing.T) {
	service := NewService(
		context.Background(),
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, nil
			},
		},
		nil,
		nil,
		nil,
		nil,
		&component.MockStore[tracer.Tracer, component.ID]{
			OnGet: func(identifier component.ID) (tracer.Tracer, error) {
				return nil, &component.MockError{}
			},
		},
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}

func TestPublisherServiceRegistryStoreError(t *testing.T) {
	service := NewService(
		context.Background(),
		nil,
		&component.MockStore[registry.ObservableRegistry, component.ID]{
			OnGet: func(identifier component.ID) (registry.ObservableRegistry, error) {
				return nil, &component.MockError{}
			},
		},
		nil,
		nil,
		nil,
		nil,
		nil,
	)

	err := service.Create(MockID, &Component{})
	require.Equal(t, &component.MockError{}, err)
}
