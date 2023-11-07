package composition

import (
	"errors"
	"testing"

	"github.com/iot-for-all/device-simulation/lib/expression"
	"github.com/iot-for-all/device-simulation/lib/logger"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestLabelCollectionPositionAndStatic(t *testing.T) {
	expected := map[string]any{
		"my-label": map[string]any{
			"my-array": []any{5, 6},
		},
	}

	val := NewCollection().With(
		NewLabel("my-label", NewCollection().With(
			NewLabel("my-array", NewArray().With(
				NewPosition(5, NewStatic(5)),
			).With(
				NewPosition(6, NewStatic(6)),
			)),
		)),
	).Render(nil)

	require.Equal(t, expected, val)
}

func TestExpression(t *testing.T) {
	expected := 1
	expr := NewExpression(&expression.MockEvaluator{
		OnEvaluate: func(m map[string]any) (any, error) {
			return expected, nil
		},
	}, func(e *Expression) {
		e.Logger = &logger.MockLogger{
			OnPrintf: func(s string, i ...interface{}) {
				require.Equal(t, ExpressionErrorMessage, s)
			}, OnLevel: func(i int) logger.Logger {
				require.Equal(t, logger.Error, i)
				return e.Logger
			}, OnWith: func(s1, s2 string) logger.Logger {
				return e.Logger
			},
		}
	})

	res := expr.Render(nil)
	require.Equal(t, expected, res)
}

func TestExpressionErrorLog(t *testing.T) {
	errMock := errors.New("mock error")
	expr := NewExpression(&expression.MockEvaluator{
		OnEvaluate: func(m map[string]any) (any, error) {
			return nil, errMock
		},
	}, func(e *Expression) {
		e.Logger = &logger.MockLogger{
			OnPrintf: func(s string, i ...interface{}) {
				require.Equal(t, ExpressionErrorMessage, s)
			}, OnLevel: func(i int) logger.Logger {
				require.Equal(t, logger.Error, i)
				return e.Logger
			}, OnWith: func(s1, s2 string) logger.Logger {
				require.Equal(t, errMock.Error(), s2)
				return e.Logger
			},
		}
	})

	expr.Render(nil)
}

func TestSwapArrayPositions(t *testing.T) {
	pos := ArrayPositions{
		{
			position: 0,
		},
		{
			position: 1,
		},
	}

	pos.Swap(0, 1)

	require.Equal(t, 1, pos[0].position)
	require.Equal(t, 0, pos[1].position)
}

func TestMockRenderer(t *testing.T) {
	renderer := &MockRenderer{
		OnRender: func(m map[string]any) any {
			require.Nil(t, m)
			return nil
		},
	}

	require.Nil(t, renderer.Render(nil))
}

func TestMockEdge(t *testing.T) {
	edge := &MockEdge{
		OnEdge: func() any {
			return nil
		},
	}

	require.Nil(t, edge.Edge())
}

func TestMockNode(t *testing.T) {
	node := &MockNode{
		OnWith: func(e Edge) Node {
			require.Equal(t, &MockEdge{}, e)
			return &MockNode{}
		},
	}

	require.Equal(t, &MockNode{}, node.With(&MockEdge{}))
}