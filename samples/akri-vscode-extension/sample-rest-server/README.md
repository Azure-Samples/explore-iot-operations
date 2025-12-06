# Sample Rest Server

Run the following commands to build a sample rest server docker image:

```bash
    cd preview/akri-connectors-extension/SampleRestServer 
    docker build -t rest-server:latest .
```

**NOTE:**: This rest server is unauthenticated and it should be accessible at port 3000 during container run.