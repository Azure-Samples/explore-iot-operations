// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package edge

import (
	"github.com/explore-iot-ops/samples/krill/components/node"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/explore-iot-ops/samples/krill/lib/composition"
)

type Store component.Store[composition.Edge, component.ID]

type Type string

const (
	LABEL    Type = "label"
	POSITION Type = "position"
)

type Component struct {
	ParentNodeId  component.ID
	ChildNodeId   component.ID
	Type          Type
	Configuration any
}

func NewStore() Store {
	return component.New[composition.Edge, component.ID]()
}

type Service struct {
	Store
	nodeStore node.Store
}

func NewService(store Store, nodeStore node.Store) *Service {
	return &Service{
		Store:     store,
		nodeStore: nodeStore,
	}
}

func (service *Service) Create(id component.ID, c *Component) error {
	if c.ParentNodeId == c.ChildNodeId {
		return &IdentifierConflictError{
			identifier: id,
			invalid:    c.ChildNodeId,
		}
	}

	parent, err := service.nodeStore.Get(c.ParentNodeId)
	if err != nil {
		return err
	}

	parentNode, ok := parent.(composition.Node)
	if !ok {
		return &InvalidParentNodeTypeError{
			identifier:           id,
			parentNodeIdentifier: c.ParentNodeId,
		}
	}

	child, err := service.nodeStore.Get(c.ChildNodeId)
	if err != nil {
		return err
	}

	var edge composition.Edge
	switch c.Type {
	case LABEL:
		val, ok := c.Configuration.(string)
		if !ok {
			return &InvalidLabelError{
				identifier: id,
			}
		}

		edge = composition.NewLabel(val, child)
		parentNode.With(edge)
	case POSITION:
		val, ok := c.Configuration.(int)
		if !ok {
			return &InvalidPositionError{
				identifier: id,
			}
		}

		edge = composition.NewPosition(val, child)
		parentNode.With(edge)
	default:
		return &InvalidTypeError{
			kind:       string(c.Type),
			identifier: id,
		}
	}

	return service.Store.Create(edge, id)
}
