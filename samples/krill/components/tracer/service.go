package tracer

import (
	"github.com/iot-for-all/device-simulation/components/observer"
	"github.com/iot-for-all/device-simulation/components/registry"
	"github.com/iot-for-all/device-simulation/lib/component"
	"github.com/iot-for-all/device-simulation/lib/logger"
)

type Store component.Store[Tracer, component.ID]

type Component struct {
	RegistryID component.ID
}

type Service struct {
	Store
	registryStore registry.Store
	Logger        logger.Logger
}

func NewStore() Store {
	return component.New[Tracer, component.ID]()
}

func NewService(store Store, registryStore registry.Store, options ...func(*Service)) *Service {
	service := &Service{
		Store:         store,
		registryStore: registryStore,
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

	return service.Store.Create(New(reg, func(bt *BlockingTracer) {
		bt.Logger = service.Logger
	}), id)
}
