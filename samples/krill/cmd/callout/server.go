package main

import (
	"fmt"
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/iot-for-all/device-simulation/lib/logger"
)

type InvalidMethodError struct {
	method string
}

func (err *InvalidMethodError) Error() string {
	return fmt.Sprintf("%q is not a support http method", err.method)
}

type Server struct {
	app           *fiber.App
	configuration HTTPServer
	outputs       *OutputCollection
	Logger        logger.Logger
}

func New(app *fiber.App, configuration HTTPServer, outputs *OutputCollection, options ...func(*Server)) *Server {
	server := &Server{
		app:           app,
		configuration: configuration,
		outputs:       outputs,
		Logger:        &logger.NoopLogger{},
	}

	for _, option := range options {
		option(server)
	}

	return server
}

func (server *Server) Start() error {
	for _, resource := range server.configuration.Resources {
		server.Logger.Level(logger.Info).With("method", resource.Method).With("status", fmt.Sprintf("%d", resource.Status)).With("path", resource.Path).Printf("registering new route")
		err := server.Resource(resource)
		if err != nil {
			return err
		}
	}

	server.Logger.Level(logger.Info).With("port", fmt.Sprintf("%d", server.configuration.Port)).Printf("configuration parsed successfully, now hosting server")
	return server.app.Listen(fmt.Sprintf(":%d", server.configuration.Port))
}

func (server *Server) Resource(resource Resource) error {
	f, err := server.Handlerfunc(resource)
	if err != nil {
		return err
	}
	switch strings.ToLower(resource.Method) {
	case "get":
		server.app.Get(resource.Path, f)
	case "post":
		server.app.Post(resource.Path, f)
	case "put":
		server.app.Put(resource.Path, f)
	case "patch":
		server.app.Put(resource.Path, f)
	default:
		return &InvalidMethodError{
			method: resource.Method,
		}
	}

	return nil
}

func (server *Server) Handlerfunc(resource Resource) (func(c *fiber.Ctx) error, error) {

	outputs := make([]Out, len(resource.Outputs))

	for index, output := range resource.Outputs {
		o, err := server.outputs.Get(output)
		if err != nil {
			return nil, err
		}
		outputs[index] = o
	}

	return func(c *fiber.Ctx) error {
		server.Logger.Level(logger.Debug).With("ip", c.IP()).With("method", c.Method()).Printf("incoming request")

		body := c.Body()

		for _, output := range outputs {
			err := output.Out(body)
			if err != nil {
				server.Logger.Level(logger.Error).With("error", err.Error()).Printf("could not output request body")
			}
		}

		c.Status(resource.Status)
		return c.Send([]byte(resource.Response))
	}, nil
}
