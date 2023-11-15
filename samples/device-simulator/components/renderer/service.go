// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package renderer

import (
	"github.com/explore-iot-ops/samples/device-simulator/components/formatter"
	"github.com/explore-iot-ops/samples/device-simulator/components/node"
	"github.com/explore-iot-ops/samples/device-simulator/lib/component"
)

type Store component.Store[Renderer, component.ID]

type Component struct {
	FormatterID component.ID
	NodeID      component.ID
}

type Service struct {
	Store
	formatterStore formatter.Store
	nodeStore      node.Store
}

func NewStore() Store {
	return component.New[Renderer, component.ID]()
}

func NewService(
	store Store,
	formatterStore formatter.Store,
	nodeStore node.Store,
) *Service {
	return &Service{
		Store:          store,
		formatterStore: formatterStore,
		nodeStore:      nodeStore,
	}
}

func (service *Service) Create(id component.ID, c *Component) error {

	fmtr, err := service.formatterStore.Get(c.FormatterID)
	if err != nil {
		return err
	}

	nd, err := service.nodeStore.Get(c.NodeID)
	if err != nil {
		return err
	}

	return service.Store.Create(New(nd, fmtr), id)
}
