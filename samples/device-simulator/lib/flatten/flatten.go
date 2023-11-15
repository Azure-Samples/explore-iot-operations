// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package flatten

import (
	"errors"
	"fmt"
	"time"
)

var (
	ErrInvalidType = errors.New("this type cannot be flattened")
)

type Flattener interface {
	Flatten(parent string, entry any) ([]Field, error)
}

type CSVFlattener struct {
	MergeStrings      func(string, string) string
	MergeStringAndInt func(string, int) string
	FormatDatetime    func(time.Time) string
	FormatFloat       func(float64) string
}

func New(options ...func(*CSVFlattener)) *CSVFlattener {
	flattener := &CSVFlattener{
		MergeStrings: func(s1, s2 string) string {
			return fmt.Sprintf("%s__%s", s1, s2)
		}, MergeStringAndInt: func(s string, i int) string {
			return fmt.Sprintf("%s__field_%d", s, i)
		}, FormatDatetime: func(t time.Time) string {
			return t.Format(time.UnixDate)
		}, FormatFloat: func(f float64) string {
			return fmt.Sprintf("%0.2f", f)
		},
	}

	for _, option := range options {
		option(flattener)
	}

	return flattener
}

type Field struct {
	Key   string
	Value string
}

func (flattener *CSVFlattener) Flatten(
	parent string,
	entry any,
) ([]Field, error) {

	var fields []Field

	switch e := entry.(type) {
	case map[string]any:
		for k, v := range e {
			res, err := flattener.Flatten(flattener.MergeStrings(parent, k), v)
			if err != nil {
				return nil, err
			}
			fields = append(fields, res...)
		}
	case []any:
		for idx, v := range e {
			res, err := flattener.Flatten(flattener.MergeStringAndInt(parent, idx), v)
			if err != nil {
				return nil, err
			}
			fields = append(fields, res...)
		}
	case int:
		return []Field{{
			Key:   parent,
			Value: fmt.Sprintf("%d", e),
		}}, nil
	case float64:
		return []Field{{
			Key:   parent,
			Value: flattener.FormatFloat(e),
		}}, nil
	case string:
		return []Field{{
			Key:   parent,
			Value: e,
		}}, nil
	case time.Time:
		return []Field{{
			Key:   parent,
			Value: flattener.FormatDatetime(e),
		}}, nil
	default:
		return nil, ErrInvalidType
	}

	return fields, nil
}

type MockFlattener struct {
	OnFlatten func(parent string, entry any) ([]Field, error)
}

func (flattener *MockFlattener) Flatten(
	parent string,
	entry any,
) ([]Field, error) {
	return flattener.OnFlatten(parent, entry)
}
