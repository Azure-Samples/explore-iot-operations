// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package tracer

import (
	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/observer"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
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

func NewService(
	store Store,
	registryStore registry.Store,
	options ...func(*Service),
) *Service {
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
