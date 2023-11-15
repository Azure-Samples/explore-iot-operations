package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/explore-iot-ops/lib/env"
	"github.com/explore-iot-ops/samples/anomaly-detection/lib/configuration"
	"github.com/explore-iot-ops/samples/anomaly-detection/lib/ewma"
	"github.com/explore-iot-ops/samples/anomaly-detection/lib/payload"
	"gopkg.in/yaml.v3"

	"github.com/gofiber/fiber/v2"
)

func main() {
	err := run()
	if err != nil {
		panic(err)
	}
}

func run() error {
	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
	})

	flagParser := env.NewFlagParser()

	flags, err := flagParser.ReadFlags(map[string]any{
		"config": "./config.yml",
		"yaml":   true,
		"stdin":  true,
	})
	if err != nil {
		return err
	}

	unmarshal := yaml.Unmarshal
	if !(*flags["yaml"].(*bool)) {
		unmarshal = json.Unmarshal
	}

	configReader := env.New[configuration.Configuration](
		func(cr *env.ConfigurationReader[configuration.Configuration]) {
			cr.Unmarshal = unmarshal
			if *flags["stdin"].(*bool) {
				cr.ReadFile = func(_ string) ([]byte, error) {
					return io.ReadAll(os.Stdin)
				}
			}
		},
	)

	configuration, err := configReader.Read(*flags["config"].(*string))
	if err != nil {
		return err
	}

	temperatureAlgorithm := ewma.New(func(e *ewma.EMWA) {
		e.L = configuration.AlgorithmConfiguration.TemperatureSettings.EMWALFactor
		e.Lambda = configuration.AlgorithmConfiguration.TemperatureSettings.EMWALambdaFactor
	})

	temperatureSeries := ewma.NewEstimatedControlSeries(temperatureAlgorithm, func(ecs *ewma.EstimatedControlSeries) {
		ecs.T = configuration.AlgorithmConfiguration.TemperatureSettings.ControlLimitT
		ecs.S = configuration.AlgorithmConfiguration.TemperatureSettings.ControlLimitS
	})

	pressureAlgorithm := ewma.New(func(e *ewma.EMWA) {
		e.L = configuration.AlgorithmConfiguration.PressureSettings.EMWALFactor
		e.Lambda = configuration.AlgorithmConfiguration.PressureSettings.EMWALambdaFactor
	})

	pressureSeries := ewma.NewEstimatedControlSeries(pressureAlgorithm, func(ecs *ewma.EstimatedControlSeries) {
		ecs.T = configuration.AlgorithmConfiguration.PressureSettings.ControlLimitT
		ecs.S = configuration.AlgorithmConfiguration.PressureSettings.ControlLimitS
	})

	vibrationAlgorithm := ewma.New(func(e *ewma.EMWA) {
		e.L = configuration.AlgorithmConfiguration.VibrationSettings.EMWALFactor
		e.Lambda = configuration.AlgorithmConfiguration.VibrationSettings.EMWALambdaFactor
	})

	vibrationSeries := ewma.NewEstimatedControlSeries(vibrationAlgorithm, func(ecs *ewma.EstimatedControlSeries) {
		ecs.T = configuration.AlgorithmConfiguration.VibrationSettings.ControlLimitT
		ecs.S = configuration.AlgorithmConfiguration.VibrationSettings.ControlLimitS
	})

	app.Get(configuration.ServerConfiguration.AnomalyDetectionRoute, func(c *fiber.Ctx) error {
		var payload payload.InputPayload
		err := json.Unmarshal(c.Body(), &payload)
		if err != nil {
			return err
		}

		vibRes := vibrationSeries.Next(payload.Payload.Vibration)
	})

	return app.Listen(fmt.Sprintf(":%d", configuration.ServerConfiguration.Port))
}
