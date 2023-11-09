package node

import (
	"go/parser"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/explore-iot-ops/samples/krill/lib/composition"
	"github.com/explore-iot-ops/samples/krill/lib/expression"
)

type Store component.Store[composition.Renderer, component.ID]

type Type string

const (
	EXPRESSION Type = "expression"
	COLLECTION Type = "collection"
	ARRAY      Type = "array"
)

type Component struct {
	Type          Type
	Configuration string
}

type Service struct {
	Store
	Logger logger.Logger
}

func NewStore() Store {
	return component.New[composition.Renderer, component.ID]()
}

func NewService(store Store, options ...func(*Service)) *Service {
	service := &Service{
		Store:  store,
		Logger: &logger.NoopLogger{},
	}

	for _, option := range options {
		option(service)
	}

	return service
}

func (service *Service) Create(id component.ID, c *Component) error {

	var node composition.Renderer
	switch c.Type {
	case EXPRESSION:
		psr, err := parser.ParseExpr(c.Configuration)
		if err != nil {
			return err
		}

		node = composition.NewExpression(expression.New(psr), func(e *composition.Expression) {
			e.Logger = service.Logger
		})
	case COLLECTION:
		node = composition.NewCollection()
	case ARRAY:
		node = composition.NewArray()
	default:
		return &InvalidTypeError{
			kind:       string(c.Type),
			identifier: string(id),
		}
	}

	return service.Store.Create(node, id)
}
