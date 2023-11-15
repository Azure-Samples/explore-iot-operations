package ewma

import (
	"math"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestEMWA(t *testing.T) {
	emwa := New()
	res := emwa.EMWA(1, 0)
	require.Equal(t, 0.25, res)

	res = emwa.EMWA(-0.5, res)
	require.Equal(t, 0.0625, (res))

	res = emwa.EMWA(0.0, res)
	require.Equal(t, 0.046875, (res))
}

func TestMean(t *testing.T) {
	emwa := New()
	mean := emwa.Mean(1, 1, 0)
	require.Equal(t, 1.0, mean)

	mean = emwa.Mean(2, 2, mean)
	require.Equal(t, 1.5, mean)

	mean = emwa.Mean(3, 3, mean)
	require.Equal(t, 2.0, mean)
}

func TestSquareSum(t *testing.T) {
	emwa := New()
	obs := 0.0
	mean := emwa.Mean(1, obs, 0)
	sum := emwa.SquareSum(obs, 0, mean, 0)
	require.Equal(t, 0.0, sum)

	obs = 1.0
	nextMean := emwa.Mean(2, obs, mean)
	sum = emwa.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 0.5, sum)
	mean = nextMean

	obs = 5.0
	nextMean = emwa.Mean(3, obs, mean)
	sum = emwa.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 14.0, sum)
	mean = nextMean

	obs = 2.0
	nextMean = emwa.Mean(4, obs, mean)
	sum = emwa.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 14.0, sum)
	mean = nextMean

	obs = 10.0
	nextMean = emwa.Mean(5, obs, mean)
	sum = emwa.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 65.2, sum)
	mean = nextMean
}

func TestControlLimit(t *testing.T) {
	emwa := New()
	stdDev := 10.0

	// Require that the theoretical upper bound is larger than the control limit.
	limit := emwa.ControlLimit(10, stdDev)
	require.Greater(t, math.Sqrt(emwa.Lambda/(2-emwa.Lambda))*float64(emwa.L)*stdDev, limit)

	// Test convergence after a large iteration number.
	limit = emwa.ControlLimit(100, stdDev)
	require.InEpsilon(t, math.Sqrt(emwa.Lambda/(2-emwa.Lambda))*float64(emwa.L)*stdDev, limit, 0.000000001)
}