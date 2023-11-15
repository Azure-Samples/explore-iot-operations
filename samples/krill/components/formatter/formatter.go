// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package formatter provides the implementation of the formatter component of the simulation framework.
package formatter

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"errors"
	"io"

	protoEncoder "github.com/explore-iot-ops/lib/proto"
	binaryEncoder "github.com/explore-iot-ops/samples/krill/lib/binary"
	"github.com/explore-iot-ops/samples/krill/lib/flatten"
	"google.golang.org/protobuf/proto"
)

var (
	ErrCannotFormatCSV        = errors.New("the CSV could not be formatted")
	ErrInconsistentCSVColumns = errors.New(
		"each row in the CSV should be the same length",
	)
	ErrCannotParseBinary       = errors.New("binary payloads cannot be parsed")
	ErrInvalidBinaryFormatType = errors.New(
		"cannot format this type into binary",
	)
)

type Formatter interface {
	Format(any) ([]byte, error)
	Parse([]byte) (any, error)
}

type MarshallerUnmarshaller interface {
	Marshal(v any) ([]byte, error)
	Unmarshal(data []byte, v any) error
}

type Json struct{}

func (j *Json) Marshal(v any) ([]byte, error) {
	return json.Marshal(v)
}

func (j *Json) Unmarshal(data []byte, v any) error {
	return json.Unmarshal(data, v)
}

type JsonFormatter struct {
	Marshaller MarshallerUnmarshaller
}

func NewJsonFormatter(options ...func(*JsonFormatter)) *JsonFormatter {
	formatter := &JsonFormatter{
		Marshaller: &Json{},
	}

	for _, option := range options {
		option(formatter)
	}

	return formatter
}

func (formatter *JsonFormatter) Format(a any) ([]byte, error) {
	return formatter.Marshaller.Marshal(a)
}

func (formatter *JsonFormatter) Parse(b []byte) (any, error) {
	var res map[string]any
	err := formatter.Marshaller.Unmarshal(b, &res)
	return res, err
}

type BinaryFormatter struct {
	encoder binaryEncoder.Encoder
}

func NewBinaryFormatter(encoder binaryEncoder.Encoder) *BinaryFormatter {
	return &BinaryFormatter{
		encoder: encoder,
	}
}

func (formatter *BinaryFormatter) Format(a any) ([]byte, error) {
	return formatter.encoder.Encode(a)
}

func (formatter *BinaryFormatter) Parse([]byte) (any, error) {
	return nil, ErrCannotParseBinary
}

type CSVFormatter struct {
	flattener    flatten.Flattener
	CreateWriter func(w io.Writer) Writer
}

type Writer interface {
	WriteAll(records [][]string) error
}

func NewCSVFormatter(
	flattener flatten.Flattener,
	options ...func(*CSVFormatter),
) *CSVFormatter {
	formatter := &CSVFormatter{
		flattener: flattener,
		CreateWriter: func(w io.Writer) Writer {
			return csv.NewWriter(w)
		},
	}

	for _, option := range options {
		option(formatter)
	}

	return formatter
}

func (formatter *CSVFormatter) Format(a any) ([]byte, error) {

	entries, ok := a.([]any)
	if !ok {
		return nil, ErrCannotFormatCSV
	}

	res := make([][]string, len(entries)+1)

	var headers []string
	for idx, entry := range entries {
		flattened, err := formatter.flattener.Flatten("csv", entry)
		if err != nil {
			return nil, err
		}

		if idx == 0 {
			for _, field := range flattened {
				headers = append(headers, field.Key)
			}
			res[0] = headers
		}

		if len(headers) != len(flattened) {
			return nil, ErrInconsistentCSVColumns
		}

		fields := make([]string, len(flattened))
		for idx, field := range flattened {
			fields[idx] = field.Value
		}
		res[idx+1] = fields
	}

	buf := bytes.NewBuffer(nil)

	writer := formatter.CreateWriter(buf)

	err := writer.WriteAll(res)
	if err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}

func (formatter *CSVFormatter) Parse(b []byte) (any, error) {
	return nil, nil
}

type ProtobufFormatter struct {
	encoder protoEncoder.Encoder
}

func NewProtobufFormatter(encoder protoEncoder.Encoder) *ProtobufFormatter {
	return &ProtobufFormatter{
		encoder: encoder,
	}
}

func (formatter *ProtobufFormatter) Format(a any) ([]byte, error) {
	return proto.Marshal(formatter.encoder.Encode(a))
}

func (formatter *ProtobufFormatter) Parse(b []byte) (any, error) {
	message := new(protoEncoder.Message)

	err := proto.Unmarshal(b, message)
	if err != nil {
		return nil, err
	}

	return formatter.encoder.Decode(message), nil
}

type MockFormatter struct {
	OnFormat func(any) ([]byte, error)
	OnParse  func([]byte) (any, error)
}

func (formatter *MockFormatter) Format(a any) ([]byte, error) {
	return formatter.OnFormat(a)
}

func (formatter *MockFormatter) Parse(b []byte) (any, error) {
	return formatter.OnParse(b)
}
