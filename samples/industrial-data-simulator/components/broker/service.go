// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package broker

import (
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/observer"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
)

type Store component.Store[Source, component.ID]

type Component struct {
	RegistryID component.ID
	Broker     string
	Port       int
}

type Service struct {
	Store
	registryStore registry.Store
}

func NewStore() Store {
	return component.New[Source, component.ID]()
}

func NewService(store Store, registryStore registry.Store) *Service {
	return &Service{
		Store:         store,
		registryStore: registryStore,
	}
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

	return service.Store.Create(New(reg, func(b *Broker) {
		b.Broker = c.Broker
		b.Port = c.Port
	}), id)
}
