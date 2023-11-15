// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package registry

import (
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
)

type Store component.Store[ObservableRegistry, component.ID]

type Component struct{}

type Service struct {
	Store
}

func NewStore() Store {
	return component.New[ObservableRegistry, component.ID]()
}

func NewService(store Store) *Service {
	return &Service{
		Store: store,
	}
}

func (service *Service) Create(id component.ID, c *Component) error {
	return service.Store.Create(
		NewRegistry(), id)
}
