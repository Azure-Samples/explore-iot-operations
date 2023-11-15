// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package outlet

import (
	"go/parser"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/formatter"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/registry"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/expression"
)

type Store component.Store[Outlet, component.ID]

type Type string

type Component struct {
	RegistryID    component.ID
	FormatterID   component.ID
	Type          Type
	Configuration string
}

type Service struct {
	Store
	formatterStore formatter.Store
	registryStore  registry.Store
}

func NewStore() Store {
	return component.New[Outlet, component.ID]()
}

func NewService(
	store Store,
	formatterStore formatter.Store,
	registryStore registry.Store,
) *Service {
	return &Service{
		Store:          store,
		formatterStore: formatterStore,
		registryStore:  registryStore,
	}
}

func (service *Service) Create(id component.ID, c *Component) error {
	reg, err := service.registryStore.Get(c.RegistryID)
	if err != nil {
		return err
	}

	fmtr, err := service.formatterStore.Get(c.FormatterID)
	if err != nil {
		return err
	}

	psr, err := parser.ParseExpr(c.Configuration)
	if err != nil {
		return err
	}

	return service.Store.Create(
		NewPrometheusOutlet(expression.New(psr), fmtr, reg),
		id,
	)
}
