// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"time"

	"github.com/explore-iot-ops/samples/http-grpc-shift-calculation/lib/shift"
)

type InvalidMessageTypeError struct{}

func (err *InvalidMessageTypeError) Error() string {
	return "invalid message type"
}

type MissingTimestampError struct{}

func (err *MissingTimestampError) Error() string {
	return "missing timestamp"
}

type InvalidShiftTimestampError struct{}

func (err *InvalidShiftTimestampError) Error() string {
	return "invalid shift timestamp"
}

type ShiftHandler struct {
	calculator *shift.ShiftCalculator
}

func NewShiftHandler(
	calculator *shift.ShiftCalculator,
	options ...func(*ShiftHandler),
) *ShiftHandler {
	handler := &ShiftHandler{
		calculator: calculator,
	}

	for _, option := range options {
		option(handler)
	}

	return handler
}

func (handler *ShiftHandler) CalculateShift(message any) (map[string]any, error) {
	res, ok := message.(map[string]any)
	if !ok {
		return nil, &InvalidMessageTypeError{}
	}

	shiftTimestamp, ok := res["timestamp"]
	if !ok {
		return nil, &MissingTimestampError{}
	}

	timestampString, ok := shiftTimestamp.(string)
	if !ok {
		return nil, &InvalidShiftTimestampError{}
	}

	timestamp, err := time.Parse(time.RFC3339, timestampString)
	if err != nil {
		return nil, err
	}

	_, shift := handler.calculator.Calculate(timestamp)

	res["shift"] = shift

	return res, nil
}
