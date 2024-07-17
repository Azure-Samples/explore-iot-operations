// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/dapr/go-sdk/client"
	"github.com/dapr/go-sdk/workflow"
)

// var (
// 	daprClient client.Client
// 	err        error
// 	ctx        context.Context
// )

// var messageSub = &common.Subscription{
// 	PubsubName: PUBSUB_NAME,
// 	Topic:      "myactor",
// 	Route:      "/myactor",
// 	Metadata:   map[string]string{"rawPayload": "true"},
// }

var stage = 0

const (
	PUBSUB_NAME     = "aio-mq-pubsub"
	STATESTORE_NAME = "aio-mq-statestore"
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
	//	defer w.Shutdown()
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
	fmt.Println("TestActivity registered")

	// Start workflow runner
	if err := w.Start(); err != nil {
		log.Fatal("Failed to start workflow runner: ", err)
	}
	fmt.Println("Runner started")

	// create a Dapr service
	// s := daprd.NewService(":6001")

	// if err := s.AddTopicEventHandler(messageSub, eventHandler(c)); err != nil {

	// 	log.Fatalf("error adding topic subscription: %v", err)
	// }

	// if err := s.Start(); err != nil && err != http.ErrServerClosed {
	// 	log.Fatalf("error listening: %v", err)
	// }

	wfClient, err := workflow.NewClient()
	if err != nil {
		log.Fatal("Failed to initialise workflow client: ", err)
	}

	fmt.Printf("stage: %d\n", stage)

	ctx := context.Background()
	id, err := wfClient.ScheduleNewWorkflow(ctx, "TestWorkflow", workflow.WithInput(1))
	if err != nil {
		log.Fatal("Failed to schedule a new workflow: ", err)
	}
	fmt.Println("Workflow started with id: ", id)

	fmt.Printf("stage: %d\n", stage)

	if err := wfClient.RaiseEvent(ctx, id, "testEvent"); err != nil {
		log.Fatal("Failed to raise event: ", err)
	}
	fmt.Println("Event raised")

	fmt.Printf("stage: %d\n", stage)

	metadata, err := wfClient.WaitForWorkflowCompletion(ctx, id)
	if err != nil {
		log.Fatal("Failed to wait for workflow: ", err)
	}
	fmt.Println("Workflow complete status:", metadata.RuntimeStatus.String())

	fmt.Printf("stage: %d\n", stage)
}

// func eventHandler(daprClient client.Client) common.TopicEventHandler {
// 	return func(ctx context.Context, e *common.TopicEvent) (retry bool, err error) {
// 		fmt.Println("event: Topic:%s, ID:%s, Data:%s", e.Topic, e.ID, e.Data)

// 		// Send to service bus
// 		// in := &dapr.InvokeBindingRequest{Name: SERVICE_BUS_NAME, Operation: "create", Data: []byte(e.RawData)}
// 		// if err := c.InvokeOutputBinding(ctx, in); err != nil {
// 		// 	panic(err)
// 		// }
// 		//log.Println("event: Sent message to service bus")

// 		return false, nil
// 	}
// }

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
		fmt.Println("err 1")
		return nil, err
	}

	err := ctx.WaitForExternalEvent("testEvent", time.Second*60).Await(&output)
	if err != nil {
		fmt.Println("err 2")
		return nil, err
	}

	if err := ctx.CallActivity(TestActivity, workflow.ActivityInput(input)).Await(&output); err != nil {
		fmt.Println("err 3")
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

	return fmt.Sprintln("Workflow stage: %d", stage), nil
}
