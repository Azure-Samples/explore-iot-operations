// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package formatter

import (
	"encoding/binary"

	"github.com/explore-iot-ops/lib/proto"
	encoder "github.com/explore-iot-ops/samples/industrial-data-simulator/lib/binary"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/component"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/flatten"
)

type Store component.Store[Formatter, component.ID]

type Type string

const (
	JSON          Type = "json"
	LITTLE_ENDIAN Type = "littleEndian"
	BIG_ENDIAN    Type = "bigEndian"
	CSV           Type = "csv"
	PROTOBUF      Type = "protobuf"
)

type Component struct {
	Type Type
}

type Service struct {
	Store
}

func NewStore() Store {
	return component.New[Formatter, component.ID]()
}

func NewService(store Store) *Service {
	return &Service{
		Store: store,
	}
}

func (service *Service) Create(id component.ID, c *Component) error {
	var formatter Formatter
	switch c.Type {
	case JSON:
		formatter = NewJsonFormatter()
	case LITTLE_ENDIAN:
		formatter = NewBinaryFormatter(encoder.New(binary.LittleEndian))
	case BIG_ENDIAN:
		formatter = NewBinaryFormatter(encoder.New(binary.BigEndian))
	case CSV:
		formatter = NewCSVFormatter(flatten.New())
	case PROTOBUF:
		formatter = NewProtobufFormatter(proto.New())
	default:
		return &InvalidTypeError{
			identifier: string(id),
			kind:       string(c.Type),
		}
	}

	return service.Store.Create(formatter, id)
}
