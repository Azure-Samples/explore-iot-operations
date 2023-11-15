// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package formatter

import (
	"testing"

	"github.com/explore-iot-ops/samples/krill/lib/component"
	"github.com/stretchr/testify/require"
)

const (
	MockID          = "MockID"
	MockInvalidType = "MockInvalidType"
)

func TestStore(t *testing.T) {
	store := NewStore()
	_, ok := store.(*component.Memstore[Formatter, component.ID])
	require.True(t, ok)
}

func TestFormatterServiceJSON(t *testing.T) {
	service := NewService(&component.MockStore[Formatter, component.ID]{
		OnCreate: func(entity Formatter, identifier component.ID) error {
			_, ok := entity.(*JsonFormatter)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	})

	err := service.Create(MockID, &Component{
		Type: JSON,
	})
	require.NoError(t, err)
}

func TestFormatterServiceLittleEndian(t *testing.T) {
	service := NewService(&component.MockStore[Formatter, component.ID]{
		OnCreate: func(entity Formatter, identifier component.ID) error {
			_, ok := entity.(*BinaryFormatter)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	})

	err := service.Create(MockID, &Component{
		Type: LITTLE_ENDIAN,
	})
	require.NoError(t, err)
}

func TestFormatterServiceBigEndian(t *testing.T) {
	service := NewService(&component.MockStore[Formatter, component.ID]{
		OnCreate: func(entity Formatter, identifier component.ID) error {
			_, ok := entity.(*BinaryFormatter)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	})

	err := service.Create(MockID, &Component{
		Type: BIG_ENDIAN,
	})
	require.NoError(t, err)
}

func TestFormatterServiceCSV(t *testing.T) {
	service := NewService(&component.MockStore[Formatter, component.ID]{
		OnCreate: func(entity Formatter, identifier component.ID) error {
			_, ok := entity.(*CSVFormatter)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	})

	err := service.Create(MockID, &Component{
		Type: CSV,
	})
	require.NoError(t, err)
}

func TestFormatterServiceProtobuf(t *testing.T) {
	service := NewService(&component.MockStore[Formatter, component.ID]{
		OnCreate: func(entity Formatter, identifier component.ID) error {
			_, ok := entity.(*ProtobufFormatter)
			require.True(t, ok)
			require.Equal(t, MockID, string(identifier))
			return nil
		},
	})

	err := service.Create(MockID, &Component{
		Type: PROTOBUF,
	})
	require.NoError(t, err)
}

func TestFormatterServiceInvalidType(t *testing.T) {
	service := NewService(nil)

	err := service.Create(MockID, &Component{
		Type: MockInvalidType,
	})
	require.Equal(t, &InvalidTypeError{
		identifier: MockID,
		kind:       MockInvalidType,
	}, err)
}
