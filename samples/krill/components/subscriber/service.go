package subscriber

import (
	"github.com/iot-for-all/device-simulation/components/client"
	"github.com/iot-for-all/device-simulation/components/observer"
	"github.com/iot-for-all/device-simulation/components/outlet"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/components/topic"
	"github.com/iot-for-all/device-simulation/components/tracer"
	"github.com/iot-for-all/device-simulation/lib/component"
	"github.com/iot-for-all/device-simulation/lib/logger"
)

type Store component.Store[*Subscriber, component.ID]

type Component struct {
	ClientID   component.ID
	TopicID    component.ID
	OutletID   component.ID
	RegistryID component.ID
	TracerID   component.ID
	QoSLevel   int
}

type Service struct {
	Store
	clientStore   client.Store
	topicStore    topic.Store
	outletStore   outlet.Store
	registryStore registry.Store
	tracerStore   tracer.Store
	Logger        logger.Logger
}

func NewStore() Store {
	return component.New[*Subscriber, component.ID]()
}

func NewService(
	store Store,
	clientStore client.Store,
	topicStore topic.Store,
	outletStore outlet.Store,
	registryStore registry.Store,
	tracerStore tracer.Store,
	options ...func(*Service),
) *Service {
	service := &Service{
		Store:         store,
		clientStore:   clientStore,
		topicStore:    topicStore,
		outletStore:   outletStore,
		registryStore: registryStore,
		tracerStore:   tracerStore,
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

	var out outlet.Outlet
	out, err = service.outletStore.Get(c.OutletID)
	if err != nil {
		_, ok := err.(*component.NotFoundError)
		if !ok {
			return err
		}
		out = &outlet.NoopOutlet{}
	}

	cli, err := service.clientStore.Get(c.ClientID)
	if err != nil {
		return err
	}

	top, err := service.topicStore.Get(c.TopicID)
	if err != nil {
		return err
	}

	sub := New(cli, top, out, reg, tra, func(s *Subscriber) {
		s.QoS = c.QoSLevel
		s.Logger = service.Logger.With("topic", top.Render()).With("client", cli.GetName()).With("site", cli.Render())
	})
	err = sub.Start()
	if err != nil {
		return err
	}

	return service.Store.Create(sub, id)
}
