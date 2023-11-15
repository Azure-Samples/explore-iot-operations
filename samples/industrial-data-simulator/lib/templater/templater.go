// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package templater contains the templating functionality used to convert a general request body template into a body specific to a particular request.
package templater

import (
	"bytes"
	"io"
	"text/template"
)

// TemplateRenderer is an interface with a Render method.
// Render converts a generic to an io.Reader, or an error.
type TemplateRenderer[T any] interface {
	Render(vars T) (io.Reader, error)
}

type TemplateExecuter interface {
	Execute(wr io.Writer, data any) error
}

type Executor struct {
	*template.Template
}

func NewExecutor(content string) (*Executor, error) {
	templ, err := template.New("").Parse(content)
	if err != nil {
		return nil, err
	}
	return &Executor{
		templ,
	}, nil
}

// Templater is a wrapper struct around the functionality of the golang wrapper.
type Templater[T any] struct {
	template TemplateExecuter
}

// New creates a new Templater.
// It must be given a template in the form of a string as a parameter.
func New[T any](templ TemplateExecuter) *Templater[T] {
	return &Templater[T]{
		template: templ,
	}
}

// Render converts a template into an io.Reader (which can be further reduced to string) given variables specific to that template.
func (templater *Templater[T]) Render(vars T) (io.Reader, error) {
	var buffer bytes.Buffer
	err := templater.template.Execute(&buffer, vars)
	if err != nil {
		return nil, err
	}

	return &buffer, nil
}

type NoopReader struct{}

func (*NoopReader) Read([]byte) (int, error)         { return 0, io.EOF }
func (*NoopReader) Close() error                     { return nil }
func (*NoopReader) WriteTo(io.Writer) (int64, error) { return 0, nil }

type NoopRenderer[T any] struct {
}

func (renderer *NoopRenderer[T]) Render(vars T) (io.Reader, error) {
	return &NoopReader{}, nil
}

type MockRenderer[T any] struct {
	OnRender func(vars T) (io.Reader, error)
}

func (renderer *MockRenderer[T]) Render(vars T) (io.Reader, error) {
	return renderer.OnRender(vars)
}

type MockExecutor struct {
	OnExecute func(wr io.Writer, data any) error
}

func (executor *MockExecutor) Execute(wr io.Writer, data any) error {
	return executor.OnExecute(wr, data)
}
