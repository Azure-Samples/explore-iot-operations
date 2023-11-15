// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package topic

import (
	"github.com/explore-iot-ops/samples/krill/components/observer"
	"github.com/explore-iot-ops/samples/krill/components/registry"
	"github.com/explore-iot-ops/samples/krill/lib/component"
)

type Store component.Store[Renderer, component.ID]

type Component struct {
	RegistryID component.ID
	Name       string
}

type Service struct {
	Store
	registryStore registry.Store
}

func NewStore() Store {
	return component.New[Renderer, component.ID]()
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

	return service.Store.Create(New(reg, func(t *Topic) {
		t.Topic = c.Name
	}), id)
}
