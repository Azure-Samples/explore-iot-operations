// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

// package dialers defines interfaces for GRPC and TCP dialers which are used across various parts of the simulation framework.
// It also contains mock implementations for testing purposes and wrappers around the dial functions provided by the net and google grpc packages.
package dialer

import (
	"net"
	"time"
)

// Dialer is an interface which describes the net package's dialer functionality.
type Dialer interface {
	Dial(network string, address string) (net.Conn, error)
}

// NetDialer is an implementation of Dialer which wraps the dial functionality of the net package dial function.
type NetDialer struct {
	OnDial func(network string, address string) (net.Conn, error)
}

func New(options ...func(*NetDialer)) *NetDialer {
	dialer := &NetDialer{
		OnDial: net.Dial,
	}

	for _, option := range options {
		option(dialer)
	}

	return dialer
}

// Dial calls the net package's dial function, passing through its network type and address parameters.
func (dialer *NetDialer) Dial(
	network string,
	address string,
) (net.Conn, error) {
	return dialer.OnDial(network, address)
}

type MockDialer struct {
	OnDial func(network string, address string) (net.Conn, error)
}

func (dialer *MockDialer) Dial(
	network string,
	address string,
) (net.Conn, error) {
	return dialer.OnDial(network, address)
}

type MockConn struct {
	OnRead             func(b []byte) (n int, err error)
	OnWrite            func(b []byte) (n int, err error)
	OnClose            func() error
	OnLocalAddr        func() net.Addr
	OnRemoteAddr       func() net.Addr
	OnSetDeadline      func(t time.Time) error
	OnSetReadDeadline  func(t time.Time) error
	OnSetWriteDeadline func(t time.Time) error
}

func (conn *MockConn) Read(b []byte) (n int, err error) {
	return conn.OnRead(b)
}

func (conn *MockConn) Write(b []byte) (n int, err error) {
	return conn.OnWrite(b)
}

func (conn *MockConn) Close() error {
	return conn.OnClose()
}

func (conn *MockConn) LocalAddr() net.Addr {
	return conn.OnLocalAddr()
}

func (conn *MockConn) RemoteAddr() net.Addr {
	return conn.OnRemoteAddr()
}

func (conn *MockConn) SetDeadline(t time.Time) error {
	return conn.OnSetDeadline(t)
}

func (conn *MockConn) SetReadDeadline(t time.Time) error {
	return conn.OnSetReadDeadline(t)
}

func (conn *MockConn) SetWriteDeadline(t time.Time) error {
	return conn.OnSetWriteDeadline(t)
}

type MockAddr struct {
	OnNetwork func() string
	OnString  func() string
}

func (addr *MockAddr) Network() string {
	return addr.OnNetwork()
}

func (addr *MockAddr) String() string {
	return addr.OnString()
}

type NoopConn struct {
}

func (*NoopConn) Read(b []byte) (n int, err error) {
	return 0, nil
}

func (*NoopConn) Write(b []byte) (n int, err error) {
	return 0, nil
}

func (*NoopConn) Close() error {
	return nil
}

func (*NoopConn) LocalAddr() net.Addr {
	return &NoopAddr{}
}

func (*NoopConn) RemoteAddr() net.Addr {
	return &NoopAddr{}
}

func (*NoopConn) SetDeadline(t time.Time) error {
	return nil
}

func (*NoopConn) SetReadDeadline(t time.Time) error {
	return nil
}

func (*NoopConn) SetWriteDeadline(t time.Time) error {
	return nil
}

type NoopAddr struct {
}

func (*NoopAddr) Network() string {
	return ""
}

func (*NoopAddr) String() string {
	return ""
}
