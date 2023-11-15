// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package composition

import (
	"sort"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/krill/lib/expression"
)

const (
	ExpressionErrorMessage = "an error occurred while evaluating the expression leaf"
)

type Renderer interface {
	Render(map[string]any) any
}

type Node interface {
	Renderer
	With(Edge) Node
}

type Edge interface {
	Renderer
	Edge() any
}

// Edge implementations.
type Label struct {
	label string
	value Renderer
}

func NewLabel(label string, value Renderer) *Label {
	return &Label{
		label: label,
		value: value,
	}
}

func (label *Label) Render(env map[string]any) any {
	return label.value.Render(env)
}

func (label *Label) Edge() any {
	return label.label
}

type Position struct {
	position int
	value    Renderer
}

func NewPosition(position int, value Renderer) *Position {
	return &Position{
		position: position,
		value:    value,
	}
}

func (position *Position) Render(env map[string]any) any {
	return position.value.Render(env)
}

func (position *Position) Edge() any {
	return position.position
}

// Node implementations.
type Collection struct {
	labels []*Label
}

func NewCollection() *Collection {
	return &Collection{}
}

func (collection *Collection) With(e Edge) Node {
	collection.labels = append(collection.labels, e.(*Label))
	return collection
}

func (collection *Collection) Render(env map[string]any) any {
	m := make(map[string]any)
	for _, label := range collection.labels {
		switch r := label.Render(env).(type) {
		case Renderer:
			m[label.Edge().(string)] = r.Render(env)
		default:
			m[label.Edge().(string)] = r
		}
	}
	return m
}

type ArrayPositions []*Position

func (a ArrayPositions) Len() int {
	return len(a)
}

func (a ArrayPositions) Swap(i int, j int) {
	a[i], a[j] = a[j], a[i]
}

func (a ArrayPositions) Less(i int, j int) bool {
	return a[i].Edge().(int) < a[j].Edge().(int)
}

type Array struct {
	Positions ArrayPositions
}

func NewArray() *Array {
	return &Array{}
}

func (array *Array) With(e Edge) Node {
	array.Positions = append(array.Positions, e.(*Position))
	return array
}

func (array *Array) Render(env map[string]any) any {
	a := make([]any, len(array.Positions))

	sort.Sort(array.Positions)

	for idx, position := range array.Positions {
		a[idx] = position.Render(env)
	}

	return a
}

// Renderer implementations.
type Expression struct {
	Logger    logger.Logger
	evaluator expression.Evaluator
}

func NewExpression(
	evaluator expression.Evaluator,
	options ...func(*Expression),
) *Expression {
	expr := &Expression{
		evaluator: evaluator,
		Logger:    &logger.NoopLogger{},
	}

	for _, option := range options {
		option(expr)
	}

	return expr
}

func (expr *Expression) Render(ctx map[string]any) any {
	v, err := expr.evaluator.Evaluate(ctx)
	if err != nil {
		expr.Logger.Level(logger.Error).
			With("error", err.Error()).
			Printf(ExpressionErrorMessage)
	}
	return v
}

type Static struct {
	value any
}

func NewStatic(value any) *Static {
	return &Static{
		value: value,
	}
}

func (stat *Static) Render(map[string]any) any {
	return stat.value
}
