// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package component

import (
	"testing"

	"github.com/stretchr/testify/require"
)

const (
	NotFoundErrorMessage = "not found"
	MockErrorMessage     = "mock"
)

func TestNotFoundError(t *testing.T) {
	err := &NotFoundError{}
	require.Equal(t, NotFoundErrorMessage, err.Error())
}

func TestMockService(t *testing.T) {
	service := &MockService[struct{}, int]{
		OnCreate: func(identifier int, entity struct{}) error {
			require.Equal(t, 0, identifier)
			require.Equal(t, struct{}{}, entity)
			return nil
		},
	}
	require.NoError(t, service.Create(0, struct{}{}))
}

func TestMockStore(t *testing.T) {
	store := &MockStore[struct{}, int]{
		OnCreate: func(entity struct{}, identifier int) error {
			require.Equal(t, 0, identifier)
			require.Equal(t, struct{}{}, entity)
			return nil
		},
		OnGet: func(identifier int) (struct{}, error) {
			require.Equal(t, 0, identifier)
			return struct{}{}, nil
		},
		OnCheck: func(identifier int) error {
			require.Equal(t, 0, identifier)
			return nil
		},
		OnDelete: func(identifier int) error {
			require.Equal(t, 0, identifier)
			return nil
		},
		OnList: func() ([]int, error) {
			return nil, nil
		},
	}

	require.NoError(t, store.Create(struct{}{}, 0))
	require.NoError(t, store.Check(0))
	require.NoError(t, store.Delete(0))

	_, err := store.Get(0)
	require.NoError(t, err)

	_, err = store.List()
	require.NoError(t, err)
}

func TestMockError(t *testing.T) {
	err := &MockError{
		OnError: func() string {
			return MockErrorMessage
		},
	}

	require.Equal(t, MockErrorMessage, err.Error())
}
