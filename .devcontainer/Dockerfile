FROM mcr.microsoft.com/devcontainers/universal:2-linux

# Install mosquitto client
RUN apt-get update && apt-get install mosquitto-clients -y

# Install Step CLI
RUN wget https://dl.smallstep.com/gh-release/cli/docs-cli-install/v0.23.4/step-cli_0.23.4_amd64.deb && \
    sudo dpkg -i step-cli_0.23.4_amd64.deb && \
    rm ./step-cli_0.23.4_amd64.deb

# Install Dapr CLI
RUN wget -q https://raw.githubusercontent.com/dapr/cli/master/install/install.sh -O - | /bin/bash

# Install mqttui
RUN wget https://github.com/EdJoPaTo/mqttui/releases/download/v0.21.1/mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb && \
    sudo apt-get install ./mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb && \
    rm -rf ./mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb

# Install k9s
RUN wget https://github.com/derailed/k9s/releases/download/v0.28.0/k9s_Linux_amd64.tar.gz && \
    tar xf k9s_Linux_amd64.tar.gz --directory=/usr/local/bin k9s && \
    chmod +x /usr/local/bin/k9s && \
    rm -rf k9s_Linux_amd64.tar.gz
