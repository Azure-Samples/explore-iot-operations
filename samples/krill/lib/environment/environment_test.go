package environment

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestEnvironment(t *testing.T) {
	expected := map[string]any{"": 1}
	env := New()
	env.Set("", 1)
	require.Equal(t, expected, env.Env())
}

func TestMockEnvironment(t *testing.T) {
	env := &MockEnvironment{
		OnEnv: func() map[string]any {
			return map[string]any{"": ""}
		}, OnSet: func(s string, a any) {
			require.Equal(t, s, a)
		},
	}
	require.Equal(t, "", env.Env()[""])
	env.Set("", "")
}
