package publisher

import (
	"context"

	"github.com/iot-for-all/device-simulation/components/client"
	"github.com/iot-for-all/device-simulation/components/limiter"
	"github.com/iot-for-all/device-simulation/components/observer"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/components/renderer"
	"github.com/iot-for-all/device-simulation/components/topic"
	"github.com/iot-for-all/device-simulation/components/tracer"
	"github.com/iot-for-all/device-simulation/lib/component"
	"github.com/iot-for-all/device-simulation/lib/environment"
	"github.com/iot-for-all/device-simulation/lib/logger"
)

type Store component.Store[*Publisher, component.ID]

type Component struct {
	RegistryID        component.ID
	ClientID          component.ID
	TopicID           component.ID
	RendererID        component.ID
	LimiterID         component.ID
	TracerID          component.ID
	QoSLevel          int
	RendersPerPublish int
	MessagesRetained  bool
}

type Service struct {
	Store
	registryStore registry.Store
	clientStore   client.Store
	topicStore    topic.Store
	rendererStore renderer.Store
	limiterStore  limiter.Store
	tracerStore   tracer.Store
	ctx           context.Context
	Logger        logger.Logger
}

func NewStore() Store {
	return component.New[*Publisher, component.ID]()
}

func NewService(
	ctx context.Context,
	store Store,
	registryStore registry.Store,
	clientStore client.Store,
	topicStore topic.Store,
	rendererStore renderer.Store,
	limiterStore limiter.Store,
	tracerStore tracer.Store,
	options ...func(*Service),
) *Service {
	service := &Service{
		Store:         store,
		registryStore: registryStore,
		clientStore:   clientStore,
		topicStore:    topicStore,
		rendererStore: rendererStore,
		limiterStore:  limiterStore,
		tracerStore:   tracerStore,
		ctx:           ctx,
		Logger:        &logger.NoopLogger{},
	}

	for _, option := range options {
		option(service)
	}

	return service
}

func (service *Service) Create(id component.ID, c *Component) error {
	var reg registry.Observable
	reg, err := service.registryStore.Get(c.RegistryID)
	if err != nil {
		_, ok := err.(*component.NotFoundError)
		if !ok {
			return err
		}
		reg = &observer.NoopObservable{}
	}

	var tra tracer.Tracer
	tra, err = service.tracerStore.Get(c.TracerID)
	if err != nil {
		_, ok := err.(*component.NotFoundError)
		if !ok {
			return err
		}
		tra = tracer.NewNoopTracer()
	}

	cli, err := service.clientStore.Get(c.ClientID)
	if err != nil {
		return err
	}

	top, err := service.topicStore.Get(c.TopicID)
	if err != nil {
		return err
	}

	lim, err := service.limiterStore.Get(c.LimiterID)
	if err != nil {
		return err
	}

	ren, err := service.rendererStore.Get(c.RendererID)
	if err != nil {
		return err
	}

	pub := New(
		service.ctx,
		ren,
		cli,
		top,
		environment.New(),
		reg,
		tra,
		lim,
		func(p *Publisher) {
			p.QoS = c.QoSLevel
			p.RendersPerPublish = c.RendersPerPublish
			p.MessagesRetained = c.MessagesRetained
			p.Logger = service.Logger
			p.Name = cli.GetName()
			p.Site = cli.Render()
		},
	)
	go pub.Start()

	return service.Store.Create(pub, id)
}
