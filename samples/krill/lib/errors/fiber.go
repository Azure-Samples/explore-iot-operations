package errors

import (
	"errors"
	"fmt"
	"net/http"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/gofiber/fiber/v2"
)

var FiberMappings = map[Category]int{
	BAD_REQUEST: http.StatusBadRequest,
	NOT_FOUND:   http.StatusNotFound,
}

type FiberErrorHandler struct {
	Logger logger.Logger
}

func New(options ...func(*FiberErrorHandler)) *FiberErrorHandler {
	handler := &FiberErrorHandler{
		Logger: &logger.NoopLogger{},
	}

	for _, option := range options {
		option(handler)
	}

	return handler
}

func (handler *FiberErrorHandler) HandleError(c Context, err error) error {
	code := fiber.StatusInternalServerError

	var e *fiber.Error
	if errors.As(err, &e) {
		code = e.Code
	}

	internal, ok := err.(Error)
	if ok {
		mapping, ok := FiberMappings[internal.Code()]
		if ok {
			code = mapping
		}
	}

	if code >= fiber.StatusInternalServerError {
		handler.Logger.Level(logger.Error).With("code", fmt.Sprintf("%d", code)).Printf("an internal error occurred")
	} else {
		handler.Logger.Level(logger.Debug).With("code", fmt.Sprintf("%d", code)).Printf("an non-500-level error occurred")
	}

	err = c.Status(code).Send([]byte(err.Error()))
	if err != nil {
		handler.Logger.Level(logger.Error).With("error", err.Error()).Printf("error occurred when handling error")
		return err
	}

	return nil
}

type Context interface {
	Status(status int) Context
	Send(body []byte) error
}

type FiberContextWrapper struct {
	*fiber.Ctx
}

func (c *FiberContextWrapper) Status(status int) Context {
	return &FiberContextWrapper{
		Ctx: c.Ctx.Status(status),
	}
}

type MockContext struct {
	OnStatus func(status int) Context
	OnSend   func(body []byte) error
}

func (ctx *MockContext) Status(status int) Context {
	return ctx.OnStatus(status)
}

func (ctx *MockContext) Send(body []byte) error {
	return ctx.OnSend(body)
}
