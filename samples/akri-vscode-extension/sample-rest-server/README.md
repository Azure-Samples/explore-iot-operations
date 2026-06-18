# Sample Rest Server

Run the following commands to build a sample rest server docker image:

```bash
    cd samples/akri-vscode-extension/sample-rest-server 
    docker build -t rest-server:latest .
```

**NOTE:**: This rest server is unauthenticated and it should be accessible at port 3000 during container run.