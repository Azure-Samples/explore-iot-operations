/*
Copyright 2021 The Dapr Authors
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	dapr "github.com/dapr/go-sdk/client"
	"github.com/dapr/go-sdk/service/common"
	daprd "github.com/dapr/go-sdk/service/http"
)

type OrderDetails struct {
	Number uint   `json:"orderId"`
	Name   string `json:"item"`
}

var (
	c   dapr.Client
	err error
	ctx context.Context
)

var ordersSub = &common.Subscription{
	PubsubName: "aio-mq-pubsub",
	Topic:      "orders",
	Route:      "/orders",
}

var oddOrdersSub = &common.Subscription{
	PubsubName: "aio-mq-pubsub",
	Topic:      "odd-numbered-orders",
	Route:      "/odd-orders",
}

func init() {
	// wait for sidecar
	time.Sleep(13 * time.Second)
}

func main() {

	c, err := dapr.NewClient()
	if err != nil {
		panic(err)
	}

	// create a Dapr service
	s := daprd.NewService(":6001")

	if err := s.AddTopicEventHandler(ordersSub, eventHandler(c)); err != nil {

		log.Fatalf("error adding topic subscription: %v", err)
	}

	if err := s.AddTopicEventHandler(oddOrdersSub, oddOrdersHandler(c)); err != nil {

		log.Fatalf("error adding topic subscription: %v", err)
	}

	// add a service to service invocation handler
	if err := s.AddServiceInvocationHandler("/get-order", orderGetter(c)); err != nil {
		log.Fatalf("error adding invocation handler: %v", err)
	}

	if err := s.Start(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("error listening: %v", err)
	}
}

func eventHandler(c dapr.Client) common.TopicEventHandler {

	return func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
		log.Printf("event - PubsubName:%s, Topic:%s, ID:%s, Data: %s", e.PubsubName, e.Topic, e.ID, e.Data)

		var order OrderDetails
		s, _ := strconv.Unquote(string(e.RawData))
		err = json.Unmarshal([]byte(s), &order)
		if err != nil {
			log.Printf("Could not decode data: %v", err)
			return false, err
		}
		log.Printf("Order number is %d with name %s", order.Number, order.Name)

		// If the order Id is an odd number, republish on a new topic
		if order.Number%2 != 0 {

			// PubsubName seems to be in e.Topic when published by a pure MQTT client
			if err := c.PublishEvent(ctx, e.Topic, "odd-numbered-orders", e.Data); err != nil {
				panic(err)
			}
			log.Printf("Published to odd-numbered-orders: %v", e)
		}

		return false, nil
	}
}

func oddOrdersHandler(c dapr.Client) common.TopicEventHandler {

	return func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
		log.Printf("event - PubsubName:%s, Topic:%s, ID:%s, Data: %s", e.PubsubName, e.Topic, e.ID, e.Data)
		var order OrderDetails
		err = json.Unmarshal([]byte(e.RawData), &order)
		if err != nil {
			log.Printf("Could not decode data: %v", err)
			return false, err
		}
		log.Printf("Odd order number is %d with name %s", order.Number, order.Name)

		STATE_STORE_NAME := "aio-mq-statestore"
		if err := c.SaveState(ctx, STATE_STORE_NAME, strconv.FormatUint(uint64(order.Number), 10), []byte(order.Name), nil); err != nil {
			log.Printf("Error saving state: %v", err)
			return true, err
		}

		log.Printf("Saved order #%d", order.Number)

		return false, nil
	}
}

func orderGetter(c dapr.Client) common.ServiceInvocationHandler {
	return func(ctx context.Context, in *common.InvocationEvent) (out *common.Content, err error) {
		if in == nil {
			err = errors.New("invocation parameter required")
			return
		}
		log.Printf(
			"echo - ContentType:%s, Verb:%s, QueryString:%s, %s",
			in.ContentType, in.Verb, in.QueryString, in.Data,
		)

		STATE_STORE_NAME := "aio-mq-statestore"
		result, _ := c.GetState(ctx, STATE_STORE_NAME, string(in.Data), nil)

		out = &common.Content{
			Data:        result.Value,
			ContentType: in.ContentType,
			DataTypeURL: in.DataTypeURL,
		}
		return
	}
}

func runHandler(ctx context.Context, in *common.BindingEvent) (out []byte, err error) {
	log.Printf("binding - Data:%s, Meta:%v", in.Data, in.Metadata)
	return nil, nil
}
