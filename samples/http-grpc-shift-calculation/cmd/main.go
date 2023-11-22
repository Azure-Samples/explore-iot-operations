// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/explore-iot-ops/lib/env"
	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/lib/proto"
	"github.com/explore-iot-ops/samples/http-grpc-shift-calculation/lib/shift"
	"google.golang.org/grpc"
	"gopkg.in/yaml.v3"

	"github.com/gofiber/fiber/v2"
	"github.com/rs/zerolog/log"
)

func main() {
	err := run()
	if err != nil {
		panic(err)
	}
}

func run() error {

	fmt.Println("HTTP/GRPC Shift Calculator")

	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
	})

	flagParser := env.NewFlagParser()

	flags, err := flagParser.ReadFlags(map[string]any{
		"config": "./config.yml",
		"yaml":   true,
		"stdin":  false,
	})
	if err != nil {
		return err
	}

	unmarshal := yaml.Unmarshal
	if !(*flags["yaml"].(*bool)) {
		unmarshal = json.Unmarshal
	}

	configReader := env.New[Configuration](
		func(cr *env.ConfigurationReader[Configuration]) {
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

	lg.Level(logger.Info).Printf("parsed configuration, now configuring server and calculator")

	lis, err := net.Listen(
		"tcp",
		fmt.Sprintf(":%d", configuration.ServerConfiguration.GRPCPort),
	)
	if err != nil {
		return err
	}

	lg.Level(logger.Info).Printf("initializing shift calculator")

	shiftCalculator := shift.NewShiftCalculator(func(sc *shift.ShiftCalculator) {
		sc.Shifts = configuration.CalculatorConfiguration.Shifts
		if configuration.CalculatorConfiguration.InitialTime != "" {
			initialTime, err := time.Parse(time.RFC3339, configuration.CalculatorConfiguration.InitialTime)
			if err != nil {
				lg.Level(logger.Warn).Printf("could not parse provided initial time, reverting to UTC 00:00")
				return
			}
			sc.InitialTime = initialTime
		}
	})

	lg.Level(logger.Info).Printf("registering handler with grpc and http servers")

	shiftHandler := NewShiftHandler(shiftCalculator)

	httpLogger := lg.Tag("server").Tag("http").Level(logger.Debug)

	app.Post("/", func(c *fiber.Ctx) error {
		httpLogger.Printf("received new shift calculcation request")

		var payload map[string]any
		err := json.Unmarshal(c.Body(), &payload)
		if err != nil {
			return err
		}

		shift, err := shiftHandler.CalculateShift(payload)
		if err != nil {
			return err
		}

		httpLogger.With("timestamp", fmt.Sprintf("%v", shift["timestamp"])).With("shift", fmt.Sprintf("%v", shift["shift"])).Printf("calculated shift")

		return c.JSON(shift)
	})

	messageServer := NewGRPCMessageServer(
		shiftHandler.CalculateShift,
		&proto.ProtoEncoder{},
		func(gs *GRPCMessageServer) {
			gs.Logger = lg.Tag("server").Tag("grpc").Level(logger.Debug)
		},
	)
	grpcServer := grpc.NewServer()
	proto.RegisterSenderServer(grpcServer, messageServer)

	lg.Level(logger.Info).Printf("now serving")

	go func() {
		err := grpcServer.Serve(lis)
		if err != nil {
			panic(err)
		}
	}()

	return app.Listen(fmt.Sprintf(":%d", configuration.ServerConfiguration.HTTPPort))
}
