// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"context"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/lib/proto"
)

type GRPCMessageServer struct {
	proto.UnimplementedSenderServer
	handler func(any) (map[string]any, error)
	encoder proto.Encoder

	Logger logger.Logger
}

func NewGRPCMessageServer(
	handler func(any) (map[string]any, error),
	encoder proto.Encoder,
	options ...func(*GRPCMessageServer),
) *GRPCMessageServer {
	server := &GRPCMessageServer{
		encoder: encoder,
		handler: handler,
		Logger:  &logger.NoopLogger{},
	}

	for _, option := range options {
		option(server)
	}

	return server
}

func (server *GRPCMessageServer) Send(
	ctx context.Context,
	m *proto.Message,
) (*proto.Message, error) {
	server.Logger.Printf("received new grpc message")

	decoded := server.encoder.Decode(m)

	res, err := server.handler(decoded)
	if err != nil {
		server.Logger.With("error", err.Error()).Printf("failed to calculate shift")
		return nil, err
	}

	return server.encoder.Encode(res), nil
}
