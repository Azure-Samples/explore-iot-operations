// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package flatten

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestBasicType(t *testing.T) {
	flattener := New()

	fields, err := flattener.Flatten("key", 1)
	require.NoError(t, err)

	require.Equal(t, 1, len(fields))
	require.Equal(t, Field{
		Key:   "key",
		Value: "1",
	}, fields[0])
}

func TestBasicTypeArray(t *testing.T) {
	flattener := New()

	fields, err := flattener.Flatten("key", []any{1, "2"})
	require.NoError(t, err)

	require.Equal(t, 2, len(fields))
	require.Equal(t, []Field{{
		Key:   "key__field_0",
		Value: "1",
	}, {
		Key:   "key__field_1",
		Value: "2",
	}}, fields)
}

func TestBasicTypeMap(t *testing.T) {
	flattener := New()

	fields, err := flattener.Flatten(
		"key",
		map[string]any{"field_0": "1", "field_1": 2.0},
	)
	require.NoError(t, err)

	require.Equal(t, 2, len(fields))
	require.ElementsMatch(t, []Field{{
		Key:   "key__field_0",
		Value: "1",
	}, {
		Key:   "key__field_1",
		Value: "2.00",
	}}, fields)
}

func TestComplexTypeMap(t *testing.T) {
	flattener := New()

	fields, err := flattener.Flatten(
		"key",
		map[string]any{"field_0": "1", "field_1": []any{2, "3"}},
	)
	require.NoError(t, err)

	require.Equal(t, 3, len(fields))
	require.ElementsMatch(
		t,
		[]Field{
			{Key: "key__field_0", Value: "1"},
			{Key: "key__field_1__field_0", Value: "2"},
			{Key: "key__field_1__field_1", Value: "3"},
		},
		fields,
	)
}

func TestDatetime(t *testing.T) {
	flattener := New()

	ts := time.Now()

	fields, err := flattener.Flatten("key", ts)
	require.NoError(t, err)

	require.Equal(t, 1, len(fields))
	require.Equal(
		t,
		[]Field{{Key: "key", Value: flattener.FormatDatetime(ts)}},
		fields,
	)
}

func TestInvalidType(t *testing.T) {
	flattener := New()

	type invalid int

	_, err := flattener.Flatten("key", invalid(1))
	require.Equal(t, ErrInvalidType, err)
}
