package expression

import (
	"go/parser"
	"math"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestSimpleExpression(t *testing.T) {
	psr, err := parser.ParseExpr("1")
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(nil)
	require.NoError(t, err)

	require.Equal(t, 1, res)
}

func TestSimpleBinaryExpression(t *testing.T) {
	psr, err := parser.ParseExpr("1 + 1")
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(nil)
	require.NoError(t, err)

	require.Equal(t, 2, res)
}

func TestSimpleStringExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`"expected"`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(nil)
	require.NoError(t, err)

	require.Equal(t, "expected", res)
}

func TestSimpleStringFunctionCallExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`concat("hello", concat(" ", "world"))`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(nil)
	require.NoError(t, err)

	require.Equal(t, "hello world", res)
}

func TestStringConversionFunctionCallExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`concat("hello", concat(" ", str(100.0, 3)))`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(nil)
	require.NoError(t, err)

	require.Equal(t, "hello 100.000", res)
}

func TestSelectorExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`x.y.z`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(map[string]any{
		"x": map[string]any{
			"y": map[string]any{
				"z": 10,
			},
		},
	})
	require.NoError(t, err)

	require.Equal(t, 10, res)
}

func TestCallExpressionWithIdent(t *testing.T) {
	psr, err := parser.ParseExpr(`sin(pi)`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(map[string]any{
		"pi": math.Pi,
	})
	require.NoError(t, err)
	require.InDelta(t, 0.0, res, 0.00000001)
}

func TestCallExpressionWithNestedIdent(t *testing.T) {
	psr, err := parser.ParseExpr(`cos(x.y.z)`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(map[string]any{
		"x": map[string]any{
			"y": map[string]any{
				"z": 0.0,
			},
		},
	})
	require.NoError(t, err)
	require.Equal(t, 1.0, res)
}

func TestAllExpressions(t *testing.T) {
	psr, err := parser.ParseExpr(
		`(concat("100 =" ,concat(" ", str(-(-(cos(x.y.z - sin(2.0 * pi) - 1.0) + 99.0)), 0))))`,
	)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(map[string]any{
		"x": map[string]any{
			"y": map[string]any{
				"z": 1.0,
			},
		},
		"pi": math.Pi,
	})
	require.NoError(t, err)
	require.Equal(t, "100 = 100", res)
}

func TestRandomString(t *testing.T) {
	psr, err := parser.ParseExpr(`randstr(10)`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(nil)
	require.NoError(t, err)

	val, ok := res.(string)
	require.Equal(t, true, ok)

	require.Equal(t, 10, len(val))
}

func TestBasicTimeCallExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`now()`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(nil)
	require.NoError(t, err)

	_, ok := res.(time.Time)
	require.Equal(t, true, ok)
}

func TestTimeCallExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`delta(now(), t)`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(map[string]any{
		"t": time.Now(),
	})
	require.NoError(t, err)

	val, ok := res.(int)
	require.Equal(t, true, ok)
	require.LessOrEqual(t, 0, val)
}

func TestIntPowerExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`2 ^ 3`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(map[string]any{})
	require.NoError(t, err)

	val, ok := res.(int)
	require.Equal(t, true, ok)
	require.Equal(t, 8, val)
}

func TestFloatPowerExpression(t *testing.T) {
	psr, err := parser.ParseExpr(`2.0 ^ 3.0`)
	require.NoError(t, err)

	expr := New(psr)
	res, err := expr.Evaluate(map[string]any{})
	require.NoError(t, err)

	val, ok := res.(float64)
	require.Equal(t, true, ok)
	require.Equal(t, 8.0, val)
}
