package proto

import (
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestProtoEncodingAndDecoding(t *testing.T) {
	encoder := New()

	original := map[string]any{
		"my_arr":  []any{"1", 2, 3.0, true},
		"my_map":  map[string]any{"hello": "hello", "hello-1": 1},
		"my_elem": 66.0,
	}

	message := encoder.Encode(original)

	b, err := proto.Marshal(message)
	require.NoError(t, err)

	res := new(Message)

	err = proto.Unmarshal(b, res)
	require.NoError(t, err)

	decoded := encoder.Decode(res)

	require.Equal(t, original, decoded)
}
