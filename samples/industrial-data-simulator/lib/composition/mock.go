// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package composition

type MockRenderer struct {
	OnRender func(map[string]any) any
}

func (renderer *MockRenderer) Render(m map[string]any) any {
	return renderer.OnRender(m)
}

type MockEdge struct {
	Renderer
	OnEdge func() any
}

func (edge *MockEdge) Edge() any {
	return edge.OnEdge()
}

type MockNode struct {
	Renderer
	OnWith func(Edge) Node
}

func (node *MockNode) With(e Edge) Node {
	return node.OnWith(e)
}
