// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/dapr/go-sdk/client"
	"github.com/dapr/go-sdk/service/common"
	"github.com/dapr/go-sdk/workflow"
)

var (
	daprClient client.Client
	err        error
	ctx        context.Context
)

var messageSub = &common.Subscription{
	PubsubName: PUBSUB_NAME,
	Topic:      "myactor",
	Route:      "/myactor",
	Metadata:   map[string]string{"rawPayload": "true"},
}

var stage = 0

const (
	WORKFLOW_COMPONENT = "dapr"
	PUBSUB_NAME        = "aio-mq-pubsub"
	STATESTORE_NAME    = "aio-mq-statestore"
)

func main() {
	fmt.Println("Starting app")

	daprClient, err := client.NewClient()
	if err != nil {
		log.Fatal("Failed to create Dapr client: ", err)
	}
	defer daprClient.Close()

	w, err := workflow.NewWorker()
	if err != nil {
		log.Fatal("Failed to create worker: ", err)
	}
	fmt.Println("Worker initialized")

	// Register the workflow
	if err := w.RegisterWorkflow(TestWorkflow); err != nil {
		log.Fatal("Failed to register workflow: ", err)
	}
	fmt.Println("TestWorkflow registered")

	// Register the activity
	if err := w.RegisterActivity(TestActivity); err != nil {
		log.Fatal("Failed to register activity: ", err)
	}
	fmt.Println("TestWorkflow registered")

	// Start workflow runner
	if err := w.Start(); err != nil {
		log.Fatal("Failed to start workflow runner: ", err)
	}
	fmt.Println("runner started")

	// create a Dapr service
	// s := daprd.NewService(":6001")

	// if err := s.AddTopicEventHandler(messageSub, eventHandler(c)); err != nil {

	// 	log.Fatalf("error adding topic subscription: %v", err)
	// }

	// if err := s.Start(); err != nil && err != http.ErrServerClosed {
	// 	log.Fatalf("error listening: %v", err)
	// }

	// Start workflow test
	// ctx := context.Background()
	// respStart, err := daprClient.StartWorkflowBeta1(ctx, &client.StartWorkflowRequest{
	// 	InstanceID:        "a7a4168d-3a1c-41da-8a4f-e7f6d9c718d9",
	// 	WorkflowComponent: WORKFLOW_COMPONENT,
	// 	WorkflowName:      "TestWorkflow",
	// 	Options:           nil,
	// 	Input:             1,
	// 	SendRawInput:      false,
	// })
	// if err != nil {
	// 	log.Fatalf("failed to start workflow: %v", err)
	// }
	// fmt.Println("workflow started with id: %v", respStart.InstanceID)

	wfClient, err := workflow.NewClient()
	if err != nil {
		log.Fatal("failed to initialise workflow client: ", err)
	}

	ctx := context.Background()
	id, err := wfClient.ScheduleNewWorkflow(ctx, "BatchProcessingWorkflow", workflow.WithInput(1))
	if err != nil {
		log.Fatal("failed to schedule a new workflow: ", err)
	}
	fmt.Println("workflow started with id: %v", id)

	// Raise an event
	// err = daprClient.RaiseEventWorkflowBeta1(ctx, &client.RaiseEventWorkflowRequest{
	// 	InstanceID:        "a7a4168d-3a1c-41da-8a4f-e7f6d9c718d9",
	// 	WorkflowComponent: WORKFLOW_COMPONENT,
	// 	EventName:         "testEvent",
	// 	EventData:         "testData",
	// 	SendRawData:       false,
	// })
	//	err := wfClient.RaiseEvent(ctx, id, "testEvent")
}

func eventHandler(daprClient client.Client) common.TopicEventHandler {
	return func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
		fmt.Println("event: Topic:%s, ID:%s, Data:%s", e.Topic, e.ID, e.Data)

		// Send to service bus
		// in := &dapr.InvokeBindingRequest{Name: SERVICE_BUS_NAME, Operation: "create", Data: []byte(e.RawData)}
		// if err := c.InvokeOutputBinding(ctx, in); err != nil {
		// 	panic(err)
		// }
		//log.Println("event: Sent message to service bus")

		return false, nil
	}
}

// func runHandler(ctx context.Context, in *common.BindingEvent) (out []byte, err error) {
// 	fmt.Printf("binding - Data:%s, Meta:%v", in.Data, in.Metadata)
// 	return nil, nil
// }

func TestWorkflow(ctx *workflow.WorkflowContext) (any, error) {
	var input int
	if err := ctx.GetInput(&input); err != nil {
		return nil, err
	}
	var output string
	if err := ctx.CallActivity(TestActivity, workflow.ActivityInput(input)).Await(&output); err != nil {
		return nil, err
	}

	err := ctx.WaitForExternalEvent("testEvent", time.Second*60).Await(&output)
	if err != nil {
		return nil, err
	}

	if err := ctx.CallActivity(TestActivity, workflow.ActivityInput(input)).Await(&output); err != nil {
		return nil, err
	}

	return output, nil
}

func TestActivity(ctx workflow.ActivityContext) (any, error) {
	var input int
	if err := ctx.GetInput(&input); err != nil {
		return "", err
	}

	stage += input

	return fmt.Sprintln("Stage: %d", stage), nil
}
