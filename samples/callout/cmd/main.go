package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"

	"github.com/explore-iot-ops/lib/env"
	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/lib/proto"
	"github.com/gofiber/fiber/v2"
	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
	"gopkg.in/yaml.v3"
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

	lis, err := net.Listen(
		"tcp",
		fmt.Sprintf(":%d", configuration.GRPCServer.Port),
	)
	if err != nil {
		return err
	}

	lg := logger.NewZeroLoggerWrapper(
		log.Logger,
		func(zlw *logger.ZeroLoggerWrapper) {
			zlw.LogLevel = configuration.LoggerConfiguration.Level
		},
	)

	outputs := NewOutputCollection(
		configuration.Outputs,
		func(oc *OutputCollection) {
			oc.Logger = lg.Tag("outputs")
		},
	)

	err = outputs.Setup()
	if err != nil {
		return err
	}

	httpServer := New(app, configuration.HTTPServer, outputs, func(s *Server) {
		s.Logger = lg.Tag("server").Tag("http")
	})

	grpcOutputs := make([]Out, len(configuration.GRPCServer.Outputs))
	for index, output := range configuration.GRPCServer.Outputs {
		o, err := outputs.Get(output)
		if err != nil {
			return err
		}
		grpcOutputs[index] = o
	}

	messageServer := NewGRPCMessageServer(grpcOutputs, &proto.ProtoEncoder{}, func(gs *GRPCMessageServer) {
		gs.Logger = lg.Tag("server").Tag("grpc")
	})
	grpcServer := grpc.NewServer()
	proto.RegisterSenderServer(grpcServer, messageServer)

	go func() {
		err := grpcServer.Serve(lis)
		if err != nil {
			panic(err)
		}
	}()

	return httpServer.Start()
}
