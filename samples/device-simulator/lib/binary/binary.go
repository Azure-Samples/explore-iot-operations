// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package binary

import (
	"encoding/binary"
	"errors"
	"math"
	"time"
)

type Encoder interface {
	Encode(a any) ([]byte, error)
}

type BinaryEncoder struct {
	endian binary.ByteOrder
}

func New(endian binary.ByteOrder) *BinaryEncoder {
	return &BinaryEncoder{
		endian: endian,
	}
}

var (
	ErrInvalidFormatType = errors.New("cannot format this type into binary")
)

func (encoder *BinaryEncoder) Encode(a any) ([]byte, error) {
	var bts []byte
	switch element := a.(type) {
	case float64:
		var buffer [8]byte
		encoder.endian.PutUint64(buffer[:], math.Float64bits(element))
		bts = append(bts, buffer[:]...)
	case int:
		var buffer [4]byte
		encoder.endian.PutUint32(buffer[:], uint32(element))
		bts = append(bts, buffer[:]...)
	case string:
		bts = append(bts, []byte(element)...)
	case time.Time:
		bts = append(bts, []byte(element.String())...)
	case []any:
		for _, elem := range element {
			res, err := encoder.Encode(elem)
			if err != nil {
				return nil, err
			}
			bts = append(bts, res...)
		}
	default:
		return nil, ErrInvalidFormatType
	}

	return bts, nil
}

type MockEncoder struct {
	OnEncode func(a any) ([]byte, error)
}

func (encoder *MockEncoder) Encode(a any) ([]byte, error) {
	return encoder.OnEncode(a)
}
