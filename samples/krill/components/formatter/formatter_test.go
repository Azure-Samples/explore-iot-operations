package formatter

import (
	"errors"
	"io"
	"testing"

	"github.com/explore-iot-ops/lib/proto"
	"github.com/explore-iot-ops/samples/krill/lib/binary"
	"github.com/explore-iot-ops/samples/krill/lib/flatten"
	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestBinaryFormatter(t *testing.T) {
	expected := 1
	formatter := NewBinaryFormatter(&binary.MockEncoder{
		OnEncode: func(a any) ([]byte, error) {
			require.Equal(t, expected, a)
			return nil, nil
		},
	})

	_, err := formatter.Format(expected)
	require.NoError(t, err)

	_, err = formatter.Parse(nil)
	require.Equal(t, ErrCannotParseBinary, err)
}

func TestCSVFormatter(t *testing.T) {
	res := []flatten.Field{
		{
			Key:   "key",
			Value: "value",
		},
	}
	formatter := NewCSVFormatter(&flatten.MockFlattener{
		OnFlatten: func(parent string, entry any) ([]flatten.Field, error) {
			return res, nil
		},
	})

	_, err := formatter.Format(1)
	require.Equal(t, ErrCannotFormatCSV, err)

	_, err = formatter.Format([]any{1})
	require.NoError(t, err)
}

func TestCSVFormatterHeaderError(t *testing.T) {
	res := []flatten.Field{
		{
			Key:   "key",
			Value: "value",
		},
	}
	formatter := NewCSVFormatter(&flatten.MockFlattener{
		OnFlatten: func(parent string, entry any) ([]flatten.Field, error) {
			r := res
			res = []flatten.Field{
				{
					Key:   "key",
					Value: "value",
				},
				{
					Key:   "key-2",
					Value: "value",
				},
			}
			return r, nil
		},
	})

	_, err := formatter.Format([]any{1, 2})
	require.Equal(t, ErrInconsistentCSVColumns, err)
}

type MockWriter struct {
	writeAll func(records [][]string) error
}

func (writer *MockWriter) WriteAll(records [][]string) error {
	return writer.writeAll(records)
}

func TestCSVFormatterWriterError(t *testing.T) {
	res := []flatten.Field{
		{
			Key:   "key",
			Value: "value",
		},
	}

	mockErr := errors.New("mock error")

	formatter := NewCSVFormatter(&flatten.MockFlattener{
		OnFlatten: func(parent string, entry any) ([]flatten.Field, error) {
			return res, nil
		},
	}, func(c *CSVFormatter) {
		c.CreateWriter = func(w io.Writer) Writer {
			return &MockWriter{
				writeAll: func(records [][]string) error {
					return mockErr
				},
			}
		}
	})

	_, err := formatter.Format([]any{1})
	require.Equal(t, mockErr, err)
}

func TestProtobufFormatter(t *testing.T) {
	formatter := NewProtobufFormatter(&proto.MockEncoder{
		OnEncode: func(a any) *proto.Message {
			return &proto.Message{
				Options: &proto.Message_Integer{
					Integer: 1,
				},
			}
		}, OnDecode: func(m *proto.Message) any {
			return 1
		},
	})

	res, err := formatter.Format(1)
	require.NoError(t, err)

	_, err = formatter.Parse(res)
	require.NoError(t, err)

	_, err = formatter.Parse([]byte{0, 0})
	require.Error(t, err)
}

type MockMarshallerUnmarshaller struct {
	OnMarshal   func(v any) ([]byte, error)
	OnUnmarshal func(data []byte, v any) error
}

func (marshaller *MockMarshallerUnmarshaller) Marshal(v any) ([]byte, error) {
	return marshaller.OnMarshal(v)
}

func (marshaller *MockMarshallerUnmarshaller) Unmarshal(
	data []byte,
	v any,
) error {
	return marshaller.OnUnmarshal(data, v)
}

func TestJsonFormatter(t *testing.T) {
	formatter := NewJsonFormatter(func(jf *JsonFormatter) {
		jf.Marshaller = &MockMarshallerUnmarshaller{
			OnMarshal: func(v any) ([]byte, error) {
				return nil, nil
			}, OnUnmarshal: func(data []byte, v any) error {
				return nil
			},
		}
	})

	_, err := formatter.Format(nil)
	require.NoError(t, err)

	_, err = formatter.Parse(nil)
	require.NoError(t, err)
}
