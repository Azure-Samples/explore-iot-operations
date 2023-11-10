package main

import (
	"context"
	"encoding/json"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/lib/proto"
)

type GRPCMessageServer struct {
	proto.UnimplementedSenderServer
	outputs []Out
	encoder proto.Encoder
	Logger  logger.Logger
}

func NewGRPCMessageServer(
	outputs []Out,
	encoder proto.Encoder,
	options ...func(*GRPCMessageServer),
) *GRPCMessageServer {
	server := &GRPCMessageServer{
		outputs: outputs,
		encoder: encoder,
	}

	for _, option := range options {
		option(server)
	}

	return server
}

func (server *GRPCMessageServer) Send(
	ctx context.Context,
	m *proto.Message,
) (*proto.Empty, error) {

	server.Logger.Level(logger.Debug).Printf("received new grpc message")

	res := server.encoder.Decode(m)

	content, err := json.Marshal(res)
	if err != nil {
		return nil, err
	}

	for _, output := range server.outputs {
		err := output.Out(content)
		if err != nil {
			return nil, err
		}
	}

	return &proto.Empty{}, nil
}
