package renderer

import (
	"github.com/iot-for-all/device-simulation/components/formatter"
	"github.com/iot-for-all/device-simulation/lib/composition"
	"github.com/iot-for-all/device-simulation/lib/environment"
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