FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

# Update and install necessary packages
RUN apt-get update && apt-get install -y \
    wget \
    dpkg \
    mosquitto-clients \
    && rm -rf /var/lib/apt/lists/*

# Install Step CLI
RUN wget https://dl.smallstep.com/gh-release/cli/docs-cli-install/v0.23.4/step-cli_0.23.4_amd64.deb \
    && dpkg -i step-cli_0.23.4_amd64.deb \
    && rm step-cli_0.23.4_amd64.deb

# Install Dapr CLI
RUN wget -q https://raw.githubusercontent.com/dapr/cli/master/install/install.sh -O /tmp/install.sh \
    && chmod +x /tmp/install.sh \
    && /bin/bash /tmp/install.sh \
    && rm /tmp/install.sh

# Install mqttui
RUN wget https://github.com/EdJoPaTo/mqttui/releases/download/v0.21.1/mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb \
    && apt-get update \
    && apt-get install -y ./mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb \
    && rm mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb \
    && rm -rf /var/lib/apt/lists/*

# Install k9s
RUN wget https://github.com/derailed/k9s/releases/download/v0.32.7/k9s_Linux_amd64.tar.gz \
    && tar xf k9s_Linux_amd64.tar.gz --directory=/usr/local/bin k9s \
    && chmod +x /usr/local/bin/k9s \
    && rm -rf k9s_Linux_amd64.tar.gz
