package ewma

import (
	"math"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestEWMA(t *testing.T) {
	ewma := New()
	res := ewma.EWMA(1, 0)
	require.Equal(t, 0.25, res)

	res = ewma.EWMA(-0.5, res)
	require.Equal(t, 0.0625, (res))

	res = ewma.EWMA(0.0, res)
	require.Equal(t, 0.046875, (res))
}

func TestMean(t *testing.T) {
	ewma := New()
	mean := ewma.Mean(1, 1, 0)
	require.Equal(t, 1.0, mean)

	mean = ewma.Mean(2, 2, mean)
	require.Equal(t, 1.5, mean)

	mean = ewma.Mean(3, 3, mean)
	require.Equal(t, 2.0, mean)
}

func TestSquareSum(t *testing.T) {
	ewma := New()
	obs := 0.0
	mean := ewma.Mean(1, obs, 0)
	sum := ewma.SquareSum(obs, 0, mean, 0)
	require.Equal(t, 0.0, sum)

	obs = 1.0
	nextMean := ewma.Mean(2, obs, mean)
	sum = ewma.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 0.5, sum)
	mean = nextMean

	obs = 5.0
	nextMean = ewma.Mean(3, obs, mean)
	sum = ewma.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 14.0, sum)
	mean = nextMean

	obs = 2.0
	nextMean = ewma.Mean(4, obs, mean)
	sum = ewma.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 14.0, sum)
	mean = nextMean

	obs = 10.0
	nextMean = ewma.Mean(5, obs, mean)
	sum = ewma.SquareSum(obs, sum, nextMean, mean)
	require.Equal(t, 65.2, sum)
	mean = nextMean
}

func TestControlLimit(t *testing.T) {
	ewma := New()
	stdDev := 10.0

	// Require that the theoretical upper bound is larger than the control limit.
	limit := ewma.ControlLimit(10, stdDev)
	require.Greater(t, math.Sqrt(ewma.Lambda/(2-ewma.Lambda))*float64(ewma.L)*stdDev, limit)

	// Test convergence after a large iteration number.
	limit = ewma.ControlLimit(100, stdDev)
	require.InEpsilon(t, math.Sqrt(ewma.Lambda/(2-ewma.Lambda))*float64(ewma.L)*stdDev, limit, 0.000000001)
}
