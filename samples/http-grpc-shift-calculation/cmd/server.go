package main

import (
	"context"

	"github.com/explore-iot-ops/lib/logger"
	"github.com/explore-iot-ops/lib/proto"
)

type GRPCMessageServer struct {
	proto.UnimplementedSenderServer
}

func NewGRPCMessageServer(
	options ...func(*GRPCMessageServer),
) *GRPCMessageServer {
	server := &GRPCMessageServer{
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
	
}