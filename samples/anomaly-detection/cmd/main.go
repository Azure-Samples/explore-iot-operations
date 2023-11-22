// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/explore-iot-ops/lib/env"
	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/samples/anomaly-detection/lib/configuration"
	"github.com/explore-iot-ops/samples/anomaly-detection/lib/ewma"
	"github.com/explore-iot-ops/samples/anomaly-detection/lib/payload"

	"github.com/rs/zerolog/log"
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

	fmt.Println("EWMA Control Chart Anomaly Detector")

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

	lg := logger.NewZeroLoggerWrapper(
		log.Logger,
		func(zlw *logger.ZeroLoggerWrapper) {
			zlw.LogLevel = configuration.LoggerConfiguration.Level
		},
	)

	lg.Level(logger.Info).Printf("setting up algorithms")

	temperatureAlgorithm := ewma.New(func(e *ewma.EWMA) {
		e.L = configuration.AlgorithmConfiguration.TemperatureSettings.EWMALFactor
		e.Lambda = configuration.AlgorithmConfiguration.TemperatureSettings.EWMALambdaFactor
	})

	var temperatureSeries ewma.EWMASeries
	if configuration.AlgorithmConfiguration.TemperatureSettings.Type == "dynamic" {
		temperatureSeries = ewma.NewDynamicControlSeries(temperatureAlgorithm, func(ecs *ewma.EWMADynamicControlSeries) {
			ecs.Logger = lg.Tag("ewma").Tag("temperature").Tag("dynamic").Level(logger.Trace)
		})
	} else {
		temperatureSeries = ewma.NewEstimatedControlSeries(temperatureAlgorithm, func(ecs *ewma.EstimatedControlSeries) {
			ecs.T = configuration.AlgorithmConfiguration.TemperatureSettings.ControlLimitT
			ecs.S = configuration.AlgorithmConfiguration.TemperatureSettings.ControlLimitS
			ecs.N = configuration.AlgorithmConfiguration.TemperatureSettings.ControlLimitN
			ecs.Logger = lg.Tag("ewma").Tag("temperature").Tag("estimated").Level(logger.Trace)
		})
	}

	humidityAlgorithm := ewma.New(func(e *ewma.EWMA) {
		e.L = configuration.AlgorithmConfiguration.HumiditySettings.EWMALFactor
		e.Lambda = configuration.AlgorithmConfiguration.HumiditySettings.EWMALambdaFactor
	})

	var humiditySeries ewma.EWMASeries
	if configuration.AlgorithmConfiguration.HumiditySettings.Type == "dynamic" {
		humiditySeries = ewma.NewDynamicControlSeries(humidityAlgorithm, func(ecs *ewma.EWMADynamicControlSeries) {
			ecs.Logger = lg.Tag("ewma").Tag("humidity").Tag("dynamic").Level(logger.Trace)
		})
	} else {
		humiditySeries = ewma.NewEstimatedControlSeries(humidityAlgorithm, func(ecs *ewma.EstimatedControlSeries) {
			ecs.T = configuration.AlgorithmConfiguration.HumiditySettings.ControlLimitT
			ecs.S = configuration.AlgorithmConfiguration.HumiditySettings.ControlLimitS
			ecs.N = configuration.AlgorithmConfiguration.HumiditySettings.ControlLimitN
			ecs.Logger = lg.Tag("ewma").Tag("humidity").Tag("estimated").Level(logger.Trace)
		})

	}

	vibrationAlgorithm := ewma.New(func(e *ewma.EWMA) {
		e.L = configuration.AlgorithmConfiguration.VibrationSettings.EWMALFactor
		e.Lambda = configuration.AlgorithmConfiguration.VibrationSettings.EWMALambdaFactor
	})

	var vibrationSeries ewma.EWMASeries
	if configuration.AlgorithmConfiguration.HumiditySettings.Type == "dynamic" {
		vibrationSeries = ewma.NewDynamicControlSeries(vibrationAlgorithm, func(ecs *ewma.EWMADynamicControlSeries) {
			ecs.Logger = lg.Tag("ewma").Tag("vibration").Tag("dynamic").Level(logger.Trace)
		})
	} else {
		vibrationSeries = ewma.NewEstimatedControlSeries(vibrationAlgorithm, func(ecs *ewma.EstimatedControlSeries) {
			ecs.T = configuration.AlgorithmConfiguration.VibrationSettings.ControlLimitT
			ecs.S = configuration.AlgorithmConfiguration.VibrationSettings.ControlLimitS
			ecs.N = configuration.AlgorithmConfiguration.VibrationSettings.ControlLimitN
			ecs.Logger = lg.Tag("ewma").Tag("vibration").Tag("estimated").Level(logger.Trace)
		})
	}

	serverLogger := lg.Tag("server").Level(logger.Debug)
	tracerLogger := lg.Tag("server").Level(logger.Trace)

	app.Post(configuration.ServerConfiguration.AnomalyDetectionRoute, func(c *fiber.Ctx) error {
		var input payload.Payload[payload.InputPayload]
		err := json.Unmarshal(c.Body(), &input)
		if err != nil {
			return err
		}

		serverLogger.Printf("received new anomaly detection request")

		tracerLogger.
			With("temperature", fmt.Sprintf("%0.2f", input.Payload.Payload.Temperature)).
			With("vibration", fmt.Sprintf("%0.2f", input.Payload.Payload.Vibration)).
			With("humidity", fmt.Sprintf("%0.2f", input.Payload.Payload.Humidity)).
			With("asset_id", input.Payload.Payload.AssetID).
			With("asset_name", input.Payload.Payload.AssetName).
			With("status", input.Payload.Payload.MaintainenceStatus).
			With("name", input.Payload.Payload.Name).
			With("serial_number", input.Payload.Payload.SerialNumber).
			With("site", input.Payload.Payload.SerialNumber).
			With("source_timestamp", input.Payload.Payload.SourceTimestamp).
			With("operating_time", fmt.Sprintf("%d", input.Payload.Payload.OperatingTime)).
			With("machine_status", fmt.Sprintf("%d", input.Payload.Payload.MachineStatus)).
			Printf("parsed request")

		vibEwma, vibAnomaly := vibrationSeries.Next(input.Payload.Payload.Vibration)
		tempEwma, tempAnomaly := temperatureSeries.Next(input.Payload.Payload.Temperature)
		humEwma, humAnomaly := humiditySeries.Next(input.Payload.Payload.Humidity)

		tracerLogger.
			With("temperature", fmt.Sprintf("%0.2f", input.Payload.Payload.Temperature)).
			With("vibration", fmt.Sprintf("%0.2f", input.Payload.Payload.Vibration)).
			With("humidity", fmt.Sprintf("%0.2f", input.Payload.Payload.Humidity)).
			With("temperature_ewma", fmt.Sprintf("%0.2f", tempEwma)).
			With("vibration_ewma", fmt.Sprintf("%0.2f", vibEwma)).
			With("humidity_ewma", fmt.Sprintf("%0.2f", humEwma)).
			With("temperature_anomaly", fmt.Sprintf("%t", tempAnomaly)).
			With("vibration_anomaly", fmt.Sprintf("%t", vibAnomaly)).
			With("humidity_anomaly", fmt.Sprintf("%t", humAnomaly)).
			Printf("calculated anomaly")

		output := payload.Payload[payload.OutputPayload]{
			Payload: payload.OutputPayload{
				Payload: payload.OutputInnerPayload{
					CommonPayload:            input.Payload.Payload,
					HumidityAnomalyFactor:    humEwma,
					HumidityAnomaly:          humAnomaly,
					TemperatureAnomalyFactor: tempEwma,
					TemperatureAnomaly:       tempAnomaly,
					VibrationAnomalyFactor:   vibEwma,
					VibrationAnomaly:         vibAnomaly,
				},
			},
		}

		return c.JSON(output)
	})

	lg.Level(logger.Info).With("anomaly_detection_route", configuration.ServerConfiguration.AnomalyDetectionRoute).With("port", fmt.Sprintf("%d", configuration.ServerConfiguration.Port)).Printf("configuration completed, now serving")

	return app.Listen(fmt.Sprintf(":%d", configuration.ServerConfiguration.Port))
}
