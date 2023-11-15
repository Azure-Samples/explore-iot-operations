// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package component

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

var (
	keyOne   = "1"
	valueOne = 1
	keyTwo   = "2"
	valueTwo = 2
)

func TestCreate(t *testing.T) {
	store := New[int, string]()
	err := store.Create(valueOne, keyOne)
	require.NoError(t, err)
}

func TestGet(t *testing.T) {
	store := New[int, string]()
	err := store.Create(valueOne, keyOne)
	require.NoError(t, err)
	v, err := store.Get(keyOne)
	require.NoError(t, err)
	require.Equal(t, valueOne, v)
}

func TestDelete(t *testing.T) {
	store := New[int, string]()
	err := store.Delete(keyOne)
	require.NoError(t, err)
	err = store.Create(valueOne, keyOne)
	require.NoError(t, err)
	v, err := store.Get(keyOne)
	require.NoError(t, err)
	require.Equal(t, valueOne, v)
	err = store.Delete(keyOne)
	require.NoError(t, err)
	_, err = store.Get(keyOne)
	require.Equal(t, &NotFoundError{}, err)
}

func TestList(t *testing.T) {
	store := New[int, string]()
	_, err := store.List()
	require.NoError(t, err)
	err = store.Create(valueOne, keyOne)
	require.NoError(t, err)
	err = store.Create(valueTwo, keyTwo)
	require.NoError(t, err)
	vals, err := store.List()
	require.NoError(t, err)
	require.ElementsMatch(t, []string{keyOne, keyTwo}, vals)
}

func TestCheck(t *testing.T) {
	store := New[int, string]()
	err := store.Check(keyOne)
	require.Equal(t, &NotFoundError{}, err)
	err = store.Create(valueOne, keyOne)
	require.NoError(t, err)
	err = store.Check(keyOne)
	require.NoError(t, err)
}
