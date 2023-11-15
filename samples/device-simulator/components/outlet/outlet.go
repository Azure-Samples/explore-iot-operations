// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package outlet

import (
	"errors"

	"github.com/explore-iot-ops/samples/device-simulator/components/formatter"
	"github.com/explore-iot-ops/samples/device-simulator/components/registry"
	"github.com/explore-iot-ops/samples/device-simulator/lib/expression"
)

var (
	ErrInvalidParsedResultType = errors.New(
		"the observed message body must be parsed into a map of string to any",
	)
	ErrInvalidObservationType = errors.New(
		"only floats or integer values can be observed",
	)
)

type Outlet interface {
	Observe([]byte) error
}

type PrometheusOutlet struct {
	expression expression.Evaluator
	formatter  formatter.Formatter
	monitor    registry.Observable
}

func NewPrometheusOutlet(
	expr expression.Evaluator,
	frmt formatter.Formatter,
	monitor registry.Observable,
) *PrometheusOutlet {
	return &PrometheusOutlet{
		expression: expr,
		formatter:  frmt,
		monitor:    monitor,
	}
}

func (outlet *PrometheusOutlet) Observe(b []byte) error {
	res, err := outlet.formatter.Parse(b)
	if err != nil {
		return err
	}

	env, ok := res.(map[string]any)
	if !ok {
		return ErrInvalidParsedResultType
	}

	val, err := outlet.expression.Evaluate(env)
	if err != nil {
		return err
	}

	switch observed := val.(type) {
	case float64:
		outlet.monitor.Observe(observed)
	case int:
		outlet.monitor.Observe(float64(observed))
	default:
		return ErrInvalidObservationType
	}

	return nil
}

type NoopOutlet struct{}

func (outlet *NoopOutlet) Observe([]byte) error {
	return nil
}
