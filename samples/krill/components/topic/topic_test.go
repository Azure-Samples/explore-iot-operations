package topic

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestDefaultTopic(t *testing.T) {
	topic := New(nil)
	require.Equal(t, "/", topic.Render())
}

func TestTopic(t *testing.T) {
	expectedTopic := "/example/topic"
	topic := New(nil, func(t *Topic) {
		t.Topic = expectedTopic
	})

	require.Equal(t, expectedTopic, topic.Render())
}
