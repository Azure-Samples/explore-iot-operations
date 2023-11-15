// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package renderer

import (
	"github.com/explore-iot-ops/samples/industrial-data-simulator/components/formatter"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/composition"
	"github.com/explore-iot-ops/samples/industrial-data-simulator/lib/environment"
)

type Renderer interface {
	Render(environment.Environment, int, int) ([]byte, error)
}

type NodeRenderer struct {
	node      composition.Renderer
	formatter formatter.Formatter
}

func New(nd composition.Renderer, frmt formatter.Formatter) *NodeRenderer {
	return &NodeRenderer{
		node:      nd,
		formatter: frmt,
	}
}

func (renderer *NodeRenderer) Render(
	env environment.Environment,
	start, rows int,
) ([]byte, error) {

	res := make([]any, rows)

	for idx := 0; idx < rows; idx++ {
		env.Set("x", start+idx)
		rendered := renderer.node.Render(env.Env())
		res[idx] = rendered
		env.Set("p", rendered)
	}

	return renderer.formatter.Format(res)
}
