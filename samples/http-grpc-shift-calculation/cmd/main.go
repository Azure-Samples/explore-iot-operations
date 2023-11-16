package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/explore-iot-ops/lib/env"
	"github.com/explore-iot-ops/lib/logger"
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
		"stdin":  true,
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

	return nil
}
