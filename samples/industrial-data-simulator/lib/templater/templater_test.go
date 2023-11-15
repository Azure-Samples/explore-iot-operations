// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package templater

import (
	"io"
	"testing"
	"text/template"

	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/errors"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

type MockType struct {
	ID string
}

var (
	example  = `{"id": {{ .ID }}}`
	expected = `{"id": 1}`
	id       = "1"
)

func TestTemplater(t *testing.T) {
	templ, err := template.New("").Parse(example)
	require.NoError(t, err)

	templater := New[MockType](templ)
	reader, err := templater.Render(MockType{
		ID: id,
	})
	require.NoError(t, err)

	res, err := io.ReadAll(reader)
	require.NoError(t, err)

	require.Equal(t, expected, string(res))
}

func TestTemplaterRenderError(t *testing.T) {

	templater := New[MockType](&MockExecutor{
		OnExecute: func(wr io.Writer, data any) error {
			return errors.Mock{}
		},
	})
	_, err := templater.Render(MockType{
		ID: id,
	})
	require.Equal(t, errors.Mock{}, err)
}

func TestNoopRenderer(t *testing.T) {
	noopRenderer := &NoopRenderer[MockType]{}
	reader, err := noopRenderer.Render(MockType{})
	require.NoError(t, err)
	require.Equal(t, &NoopReader{}, reader)
}

func TestNoopReader(t *testing.T) {
	reader := &NoopReader{}

	readRes, err := reader.Read(nil)
	require.Equal(t, 0, readRes)
	require.Equal(t, io.EOF, err)

	require.NoError(t, reader.Close())

	writeRes, err := reader.WriteTo(nil)
	require.Equal(t, int64(0), writeRes)
	require.NoError(t, err)
}

func TestMockRenderer(t *testing.T) {
	mockRenderer := &MockRenderer[MockType]{
		OnRender: func(vars MockType) (io.Reader, error) {
			return nil, errors.Mock{}
		},
	}

	_, err := mockRenderer.Render(MockType{})
	require.Equal(t, errors.Mock{}, err)
}

func TestMockExecutor(t *testing.T) {
	mockExecutor := &MockExecutor{
		OnExecute: func(wr io.Writer, data any) error {
			return errors.Mock{}
		},
	}

	require.Equal(t, errors.Mock{}, mockExecutor.Execute(nil, nil))
}

func TestExecutor(t *testing.T) {
	_, err := NewExecutor("")
	require.NoError(t, err)
}

func TestExecutorParseError(t *testing.T) {
	_, err := NewExecutor("{{{}}")
	require.Error(t, err)
}
