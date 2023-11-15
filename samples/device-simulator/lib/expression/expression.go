// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package expression provides functionality to evaluate simple mathematic expressions and functions.
package expression

import (
	"errors"
	"fmt"
	"go/ast"
	"go/token"
	"math"
	"math/rand"
	"strconv"
	"strings"
	"time"
)

// Evaluator is an interface whose implementation should be able to evaluate basic expressions given an evaluation context.
// From this context, a float64 should be evaluated, or an error if an evaluation error occurs.
type Evaluator interface {
	Evaluate(map[string]any) (any, error)
}

// Errors which may occur during expression evaluation.
var (
	ErrCannotEvaluateExpr = errors.New(
		"could not evaluate expression",
	)
	ErrCannotEvaluateLiteral = errors.New("could not evaluate literal")
	ErrCallExpressionInvalid = errors.New(
		"could not evaluate call expression name",
	)
	ErrFunctionDoesNotExist        = errors.New("function does not exist")
	ErrCannotEvaluateBinaryOpToken = errors.New(
		"could not evaluate binary op token",
	)
	ErrCannotEvaluateUnaryOpToken = errors.New(
		"could not evaluate unary op token",
	)
	ErrIncorrectArgumentCount = errors.New(
		"too many or too few arguments were supplied to the function",
	)
	ErrInvalidFunctionArguments = errors.New(
		"the supplied function arguments are the correct type but are invalid",
	)
	ErrIdentNotFound = errors.New(
		"the ident could not be found in the evaluation context",
	)
	ErrUnaryExpressionMustBeNumeric = errors.New(
		"unary expressions such as '-' can only be applied on numbers",
	)
	ErrBinaryExpressionMustBeNumeric = errors.New(
		"binary expressions such as '+' or '*' can only be applied on numbers of the same type (both ints or both floats)",
	)
	ErrInvalidFunctionArgumentType = errors.New(
		"the supplied function arguments are invalid",
	)
	ErrInvalidSelector = errors.New(
		"selector cannot be used on a non-map type",
	)
)

// FunctionType is an enum representing the functions which can be evaluated by the evaluator.
type FunctionType string

// Names of each function which can be evaluated by the evaluator.
const (
	SIN     FunctionType = "sin"
	COS     FunctionType = "cos"
	TAN     FunctionType = "tan"
	ASIN    FunctionType = "asin"
	ACOS    FunctionType = "acos"
	ATAN    FunctionType = "atan"
	RAND    FunctionType = "rand"
	STR     FunctionType = "str"
	CONCAT  FunctionType = "concat"
	RANDSTR FunctionType = "randstr"
	NOW     FunctionType = "now"
	DELTA   FunctionType = "delta"
	TOINT   FunctionType = "int"
	TOFLOAT FunctionType = "float"
	AFTER   FunctionType = "after"
	ABS     FunctionType = "abs"
	PI      FunctionType = "pi"
)

type OperandType int

const (
	FLOAT OperandType = iota
	STRING
	DATETIME
	INTEGER
	VOID
)

var FunctionTypeOperandTypeMapping = map[FunctionType][]OperandType{
	SIN:     {FLOAT},
	COS:     {FLOAT},
	TAN:     {FLOAT},
	ASIN:    {FLOAT},
	ACOS:    {FLOAT},
	ATAN:    {FLOAT},
	RAND:    {INTEGER, INTEGER},
	STR:     {FLOAT, INTEGER},
	CONCAT:  {STRING, STRING},
	RANDSTR: {INTEGER},
	NOW:     {VOID},
	DELTA:   {DATETIME, DATETIME},
	AFTER:   {DATETIME, INTEGER},
	TOINT:   {FLOAT},
	TOFLOAT: {INTEGER},
	ABS:     {FLOAT},
	PI:      {VOID},
}

var OperandTypeValidationMapping = map[OperandType]func(any) bool{
	FLOAT: func(a any) bool {
		_, b := a.(float64)
		return b
	},
	STRING: func(a any) bool {
		_, b := a.(string)
		return b
	},
	DATETIME: func(a any) bool {
		_, b := a.(time.Time)
		return b
	},
	INTEGER: func(a any) bool {
		_, b := a.(int)
		return b
	},
}

const (
	letterBytes = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
)

var FunctionTypeFunctionCurryMappings = map[FunctionType]any{
	RAND: func(i0 int) any {
		return func(i1 int) any {
			return rand.Intn(i1-i0) + i0 // #nosec G404
		}
	},
	SIN:  func(f0 float64) any { return math.Sin(f0) },
	COS:  func(f0 float64) any { return math.Cos(f0) },
	TAN:  func(f0 float64) any { return math.Tan(f0) },
	ASIN: func(f0 float64) any { return math.Asin(f0) },
	ACOS: func(f0 float64) any { return math.Acos(f0) },
	ATAN: func(f0 float64) any { return math.Atan(f0) },
	STR: func(f0 float64) any {
		return func(i0 int) any {
			return fmt.Sprintf(fmt.Sprintf("%%0.%df", i0), f0)
		}
	},
	RANDSTR: func(i0 int) any {

		str := make([]byte, i0)

		randoms := rand.Perm(len(letterBytes) - 1)

		for idx := 0; idx < i0; idx++ {
			str[idx] = letterBytes[randoms[idx]]
		}

		return string(str)

	},
	TOINT: func(f0 float64) any { return int(f0) },
	CONCAT: func(s0 string) any {
		return func(s1 string) any {
			return fmt.Sprintf("%s%s", s0, s1)
		}
	},
	NOW: func() any { return time.Now() },
	DELTA: func(t0 time.Time) any {
		return func(t1 time.Time) any {
			if t0.After(t1) {
				return int(t0.Sub(t1).Milliseconds())
			} else {
				return int(t1.Sub(t0).Milliseconds())
			}
		}
	},
	TOFLOAT: func(i0 int) any { return float64(i0) },
	AFTER: func(t0 time.Time) any {
		return func(i0 int) any {
			return t0.Add(time.Duration(i0) * time.Millisecond)
		}
	},
	ABS: func(f0 float64) any { return math.Abs(f0) },
	PI:  func() any { return math.Pi },
}

// FunctionValidationMapping describes a validation function which will be run before the functions in the mapping above are called.
// This assures that no panics will occur in the evaluation of the above functions,
// and also that NaN will not be returned.
var FunctionValidationMapping = map[FunctionType]func(...float64) bool{
	SIN:  func(f ...float64) bool { return math.IsNaN(f[0]) || math.IsInf(f[0], 0) },
	COS:  func(f ...float64) bool { return math.IsNaN(f[0]) || math.IsInf(f[0], 0) },
	TAN:  func(f ...float64) bool { return math.IsNaN(f[0]) || math.IsInf(f[0], 0) },
	ASIN: func(f ...float64) bool { return f[0] < -1 || f[0] > 1 },
	ACOS: func(f ...float64) bool { return f[0] < -1 || f[0] > 1 },
	ATAN: func(f ...float64) bool { return true },
	RAND: func(f ...float64) bool { return f[0] > f[1] },
	STR: func(f ...float64) bool {
		return math.IsNaN(f[0]) || math.IsInf(f[0], 0) || math.IsNaN(f[0]) ||
			math.IsInf(f[0], 0) ||
			f[1] > 10
	},
	RANDSTR: func(f ...float64) bool {
		return math.IsNaN(f[0]) || math.IsInf(f[0], 0) || f[0] < 1
	},
}

// Expression is an implementation of evaluator.
// It holds the underlying golang AST expression and provides an evaluation function which can be applied on the given expression.
type Expression struct {
	expr ast.Expr
}

// New creates an Expression, given an ast expression.
func New(expr ast.Expr) *Expression {
	return &Expression{
		expr: expr,
	}
}

// Evaluate will resolve the expression's ast expression to a float64 value,
// given an environment of key value pairs which can be used to resolve symbols in the expression.
// An error will be returned if the expression cannot evaluate for any reason.
func (expression *Expression) Evaluate(env map[string]any) (any, error) {
	return evalExpr(env, expression.expr)
}

func evalExpr(env map[string]any, n ast.Expr) (any, error) {
	switch expr := n.(type) {
	case *ast.BinaryExpr:
		return evalBinaryExpr(env, expr)
	case *ast.CallExpr:
		return evalCallExpr(env, expr)
	case *ast.UnaryExpr:
		return evalUnaryExpr(env, expr)
	case *ast.SelectorExpr:
		return evalSelectorExpr(env, expr)
	case *ast.Ident:
		return evalIdent(env, expr)
	case *ast.ParenExpr:
		return evalExpr(env, expr.X)
	case *ast.BasicLit:
		return evalBasicLit(expr)
	default:
		return 0, ErrCannotEvaluateExpr
	}
}

func evalSelectorExpr(env map[string]any, expr *ast.SelectorExpr) (any, error) {
	res, err := evalExpr(env, expr.X)
	if err != nil {
		return 0, err
	}

	m, ok := res.(map[string]any)
	if !ok {
		return 0, ErrInvalidSelector
	}

	return evalIdent(m, expr.Sel)
}

func evalBasicLit(lit *ast.BasicLit) (any, error) {
	switch lit.Kind {
	case token.INT:
		return strconv.Atoi(lit.Value)
	case token.FLOAT:
		return strconv.ParseFloat(lit.Value, 64)
	case token.STRING:
		return strings.Trim(lit.Value, "\""), nil
	default:
		return 0, ErrCannotEvaluateLiteral
	}
}

func evalIdent(env map[string]any, ident *ast.Ident) (any, error) {
	res, ok := env[ident.Name]
	if !ok {
		return 0, ErrIdentNotFound
	}

	return res, nil
}

func evalUnaryExpr(env map[string]any, expr *ast.UnaryExpr) (any, error) {
	res, err := evalExpr(env, expr.X)
	if err != nil {
		return 0, err
	}

	switch expr.Op {
	case token.SUB:
		switch val := res.(type) {
		case float64:
			return -1 * val, nil
		case int:
			return -1 * val, nil
		default:
			return 0, ErrUnaryExpressionMustBeNumeric
		}
	default:
		return 0, ErrCannotEvaluateUnaryOpToken
	}
}

func evalCallExpr(env map[string]any, expr *ast.CallExpr) (any, error) {
	ident, ok := expr.Fun.(*ast.Ident)
	if !ok {
		return 0, ErrCallExpressionInvalid
	}

	typeMappings, ok := FunctionTypeOperandTypeMapping[FunctionType(ident.Name)]
	if !ok {
		return 0, ErrFunctionDoesNotExist
	}

	// If the function is a void function, evaluate immediately and return result.
	if typeMappings[0] == VOID {
		return FunctionTypeFunctionCurryMappings[FunctionType(ident.Name)].(func() any)(), nil
	}

	if len(typeMappings) != len(expr.Args) {
		return 0, ErrIncorrectArgumentCount
	}

	args := make([]any, len(typeMappings))

	for idx, arg := range expr.Args {
		res, err := evalExpr(env, arg)
		if err != nil {
			return 0, err
		}
		args[idx] = res
	}

	f := FunctionTypeFunctionCurryMappings[FunctionType(ident.Name)]

	for idx, opType := range typeMappings {
		if OperandTypeValidationMapping[opType](args[idx]) {
			switch opType {
			case FLOAT:
				f = f.(func(float64) any)(args[idx].(float64))
			case STRING:
				f = f.(func(string) any)(args[idx].(string))
			case DATETIME:
				f = f.(func(time.Time) any)(args[idx].(time.Time))
			case INTEGER:
				f = f.(func(int) any)(args[idx].(int))
			}
		} else {
			return 0, ErrInvalidFunctionArgumentType
		}
	}

	return f, nil
}

var BinaryExprFunctionMapping = map[OperandType]map[token.Token]any{
	FLOAT: {
		token.ADD: func(f0, f1 float64) any {
			return f0 + f1
		},
		token.SUB: func(f0, f1 float64) any {
			return f0 - f1
		},
		token.MUL: func(f0, f1 float64) any {
			return f0 * f1
		},
		token.QUO: func(f0, f1 float64) any {
			if f1 == 0 {
				return 0
			}
			return f0 / f1
		},
		token.XOR: func(f0, f1 float64) any {
			return math.Pow(f0, f1)
		},
	}, INTEGER: {
		token.ADD: func(i0, i1 int) any {
			return i0 + i1
		},
		token.SUB: func(i0, i1 int) any {
			return i0 - i1
		},
		token.MUL: func(i0, i1 int) any {
			return i0 * i1
		},
		token.QUO: func(i0, i1 int) any {
			if i1 == 0 {
				return 0
			}
			return i0 / i1
		},
		token.XOR: func(i0, i1 int) any {
			res := i0
			for count := 1; count < i1; count++ {
				res *= i0
			}
			return res
		},
		token.REM: func(i0, i1 int) any {
			if i1 == 0 {
				return 0
			}
			return i0 % i1
		},
	},
}

func evalBinaryExpr(env map[string]any, expr *ast.BinaryExpr) (any, error) {
	lhs, err := evalExpr(env, expr.X)
	if err != nil {
		return 0, err
	}

	rhs, err := evalExpr(env, expr.Y)
	if err != nil {
		return 0, err
	}

	switch lVal := lhs.(type) {
	case float64:
		rVal, ok := rhs.(float64)
		if !ok {
			return 0, ErrBinaryExpressionMustBeNumeric
		}

		mappings, ok := BinaryExprFunctionMapping[FLOAT][expr.Op]
		if !ok {
			return 0, ErrCannotEvaluateBinaryOpToken
		}

		return mappings.(func(float64, float64) any)(lVal, rVal), nil

	case int:
		rVal, ok := rhs.(int)
		if !ok {
			return 0, ErrBinaryExpressionMustBeNumeric
		}

		mappings, ok := BinaryExprFunctionMapping[INTEGER][expr.Op]
		if !ok {
			return 0, ErrCannotEvaluateBinaryOpToken
		}

		return mappings.(func(int, int) any)(lVal, rVal), nil
	default:
		return 0, ErrBinaryExpressionMustBeNumeric
	}
}

type MockEvaluator struct {
	OnEvaluate func(map[string]any) (any, error)
}

func (evaluator *MockEvaluator) Evaluate(m map[string]any) (any, error) {
	return evaluator.OnEvaluate(m)
}
