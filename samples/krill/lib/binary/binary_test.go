package binary

import (
	"encoding/binary"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestBinaryEncoderInt(t *testing.T) {
	encoder := New(binary.BigEndian)
	bts := make([]byte, 4)
	res, err := encoder.Encode(0)
	require.NoError(t, err)
	require.Equal(t, bts, res)
}

func TestBinaryEncoderFloat(t *testing.T) {
	encoder := New(binary.BigEndian)
	bts := make([]byte, 8)
	res, err := encoder.Encode(0.0)
	require.NoError(t, err)
	require.Equal(t, bts, res)
}

func TestBinaryEncoderString(t *testing.T) {
	encoder := New(binary.BigEndian)
	bts := []byte{0x41}
	res, err := encoder.Encode("A")
	require.NoError(t, err)
	require.Equal(t, bts, res)
}

func TestBinaryEncoderTime(t *testing.T) {
	encoder := New(binary.BigEndian)
	_, err := encoder.Encode(time.Now())
	require.NoError(t, err)
}

func TestBinaryEncoderArray(t *testing.T) {
	encoder := New(binary.BigEndian)
	bts := make([]byte, 12)
	res, err := encoder.Encode([]any{0, 0.0})
	require.NoError(t, err)
	require.Equal(t, bts, res)
}

func TestBinaryEncoderInvalidType(t *testing.T) {
	encoder := New(binary.BigEndian)
	type invalid int
	_, err := encoder.Encode(invalid(1))
	require.Equal(t, ErrInvalidFormatType, err)
}

func TestBinaryEncoderInvalidTypeWithinArray(t *testing.T) {
	encoder := New(binary.BigEndian)
	type invalid int
	_, err := encoder.Encode([]any{invalid(1)})
	require.Equal(t, ErrInvalidFormatType, err)
}

func TestMockEncoder(t *testing.T) {
	encoder := &MockEncoder{
		OnEncode: func(a any) ([]byte, error) {
			require.Nil(t, a)
			return nil, nil
		},
	}

	_, err := encoder.Encode(nil)
	require.NoError(t, err)
}