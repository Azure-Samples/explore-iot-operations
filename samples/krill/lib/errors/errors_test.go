package errors

import (
	"net/http"
	"testing"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/gofiber/fiber/v2"
	"github.com/stretchr/testify/require"
)

const (
	MockErrorCode        = 507
	MockErrorCodeString  = "507"
	MockErrorMessage     = "MockErrorMessage"
	MockBadRequestString = "400"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestMockError(t *testing.T) {
	err := &Mock{}
	require.Equal(t, MOCK, err.Code())
	require.Equal(t, "mock", err.Error())
}

func TestBadRequest(t *testing.T) {
	res := &BadRequest{}
	require.Equal(t, BAD_REQUEST, res.Code())
}

func TestNotFound(t *testing.T) {
	res := &NotFound{}
	require.Equal(t, NOT_FOUND, res.Code())
}

func TestFiberErrorHandlerFiberError(t *testing.T) {
	handler := New(func(feh *FiberErrorHandler) {
		feh.Logger = &logger.MockLogger{
			OnLevel: func(i int) logger.Logger {
				require.Equal(t, logger.Error, i)
				return feh.Logger
			}, OnWith: func(s1, s2 string) logger.Logger {
				require.Equal(t, "code", s1)
				require.Equal(t, MockErrorCodeString, s2)
				return feh.Logger
			}, OnPrintf: func(s string, i ...interface{}) {
				require.Equal(t, "an internal error occurred", s)
			},
		}
	})

	err := handler.HandleError(&MockContext{
		OnStatus: func(status int) Context {
			require.Equal(t, MockErrorCode, status)
			return &MockContext{
				OnSend: func(body []byte) error {
					require.Equal(t, []byte(MockErrorMessage), body)
					return nil
				},
			}
		},
	}, &fiber.Error{
		Code:    MockErrorCode,
		Message: MockErrorMessage,
	})
	require.NoError(t, err)
}

func TestFiberErrorHandlerInternalError(t *testing.T) {
	handler := New(func(feh *FiberErrorHandler) {
		feh.Logger = &logger.MockLogger{
			OnLevel: func(i int) logger.Logger {
				require.Equal(t, logger.Debug, i)
				return feh.Logger
			}, OnWith: func(s1, s2 string) logger.Logger {
				require.Equal(t, "code", s1)
				require.Equal(t, MockBadRequestString, s2)
				return feh.Logger
			}, OnPrintf: func(s string, i ...interface{}) {
				require.Equal(t, "an non-500-level error occurred", s)
			},
		}
	})

	err := handler.HandleError(&MockContext{
		OnStatus: func(status int) Context {
			require.Equal(t, http.StatusBadRequest, status)
			return &MockContext{
				OnSend: func(body []byte) error {
					require.Equal(t, []byte(MockErrorMessage), body)
					return nil
				},
			}
		},
	}, &Custom{
		code:    BAD_REQUEST,
		message: MockErrorMessage,
	})
	require.NoError(t, err)
}

func TestFiberErrorHandlerSendError(t *testing.T) {
	handler := New(func(feh *FiberErrorHandler) {
		feh.Logger = &logger.MockLogger{
			OnLevel: func(i int) logger.Logger {
				return feh.Logger
			}, OnWith: func(s1, s2 string) logger.Logger {
				return feh.Logger
			}, OnPrintf: func(s string, i ...interface{}) {
				feh.Logger = &logger.MockLogger{
					OnLevel: func(i int) logger.Logger {
						require.Equal(t, logger.Error, i)
						return feh.Logger
					}, OnWith: func(s1, s2 string) logger.Logger {
						require.Equal(t, "error", s1)
						require.Equal(t, (Mock{}).Error(), s2)
						return feh.Logger
					}, OnPrintf: func(s string, i ...interface{}) {
						require.Equal(
							t,
							"error occurred when handling error",
							s,
						)
					},
				}
			},
		}
	})

	err := handler.HandleError(&MockContext{
		OnStatus: func(status int) Context {
			require.Equal(t, http.StatusBadRequest, status)
			return &MockContext{
				OnSend: func(body []byte) error {
					return Mock{}
				},
			}
		},
	}, &Custom{
		code:    BAD_REQUEST,
		message: MockErrorMessage,
	})
	require.Equal(t, Mock{}, err)
}
