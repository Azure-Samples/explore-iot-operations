# Prerequisites

A Purdue Networking with the following networks (Purdue rules in place)
- Default Network (can access all others and be accessed from all others) 192.168.0.0/24
- Level4 192.168.104.0/24
- Level3 192.168.103.0/24
- Level2 192.168.102.0/24
- A Small Form Factor Machine or in my case a Windows WSLv2 with Ubuntu 22.04 LTS attached to the Default network and has internet access
- A Small Form Factor Machine that can be used as a single node cluster in Level4, Level3, and Level2 but start connected to default network (Beelink AMD Ryzen 7 5000 series)
- Meet minimum requirements for AIO
- Have Ubuntu 22.04 LTS installed

## Preparing the Jump Box

The jump box is where the operations will be executed from and eventually connection to the Kubernetes cluster as well as Arc connection performed. The use of the jump box is not only to "make it easier" but also to "reduce the number of whitelisted addresses". If some of these steps were performed on the actual machine they would require opening additional ports and allowing additional URI. In a real world scenario it is expected that either the customer has a similar technique, or has resolved the issues of managing these machines through other means. This guidance is not a prescriptive guide to operations so it is viewed as acceptable.

In this example the jump box in use is Ubuntu 22.04 WSLv2 instance running. 

1. If this machine has been used to establish other connections to machines it is recommended to ensure the entries for the new machines have been cleared from the known hosts (~/.ssh/knownhosts).

1. Install Kubectl client on the machine and create the required configuration file

    ```bash
    sudo  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt update -y && sudo  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y apt-transport-https ca-certificates curl gnupg
    
    # Download the the signing key for Kubernetes repository
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    
    # Add the apt repository
    sudo bash -c 'cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
    deb https://apt.kubernetes.io/ kubernetes-xenial main
    EOF'
    
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt update -y && sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y kubectl
    
    # Test it
    kubectl version
    ```

1. Install azure-cli.

    ```bash
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash 
    
    # Test it
    az version
    ```

1. Install the Docker CLI and download the Envoy Image for use later in the Kubernetes deployment.

    ```bash
    sudo  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y docker-ce-cli
    
    docker pull envoyproxy/envoy:v1.33.0
    docker save -o ./envoy_v1.33.0.tar envoyproxy/envoy:v1.33.0
    chown ${USER} ./envoy_v1.33.0.tar && chmod 777 ./envoy_v1.33.0.tar
    ```

1. Install the MQTT client tools.

    ```bash
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt update -y && sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt upgrade -y && sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y mosquitto-clients
    
    wget https://github.com/EdJoPaTo/mqttui/releases/download/v0.22.0/mqttui-v0.22.0-x86_64-unknown-linux-gnu.deb
    chmod 777 ./mqttui-v0.22.0-x86_64-unknown-linux-gnu.deb
    sudo dpkg -i ./mqttui-v0.22.0-x86_64-unknown-linux-gnu.deb
    ```

## Preparing Each Small Form Factor Machine (Starting at Jump Box)

The steps in this section will be completed for each of the machines that are to be deployed to the various Purdue levels. The host name for each machine will be set to "level\<number\>" to reflect its Purdue level i.e., Purdue Level 4 will be level4. Start with the machines attached to the Default network and review the IP Address they have been assigned making note of each. 

1. Copy the required files to the remote machine

    ```bash
    scp -r ./k3s ubuntu@<IP_Address>:~/
    ```


1. Establish an ssh session to the target machine using the IP address recorded previously

    ```bash
    ssh ubuntu@<IP_Address>
    ```

1. Add the current user to the list of users that do not have to enter their password when executing sudo commands (done for ease of future steps). When prompted enter ubuntu's password.

    ```bash
    sudo cp /etc/sudoers /etc/sudoers.bak && sudo ls && echo "${USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
    ```

1. Update the host name and adjust the hosts file to match.

    ```bash
    oldHostName=${HOSTNAME}
    
    sudo hostnamectl set-hostname <Host_Name>
    sudo sed -i "/127.0.1.1 ${oldHostName}/c\\127.0.1.1 level<level>" /etc/hosts
    ```

1. Update the OS and packages, installing some basics

    ```bash
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt update -y && sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt upgrade -y && sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt install -y nano wget curl iputils-ping ca-certificates
    ```

1. Disable the firewall for ease of troubleshooting in the demo if it arises.

    ```bash
    sudo ufw disable && sudo systemctl stop ufw
    ```

1. Setup the K3s files required for air gapped install (if level4 the decision may be made to load from the internet).

    ```bash
    sudo mkdir -p /var/lib/rancher/k3s/agent/images/ && sudo cp k3s/k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/ && sudo chown ${USER} /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst && sudo chmod 755 /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst
    
    sudo cp k3s/k3s /usr/local/bin/ && sudo chown ${USER} /usr/local/bin/k3s && sudo chmod 777 /usr/local/bin/k3s
    
    sudo chown ${USER} k3s/install.sh && sudo chmod 755 k3s/install.sh
    ```

1. Install K9s for easy visualization of the cluster.

    ```bash
    tar xf k3s/k9s_Linux_amd64.tar.gz && sudo mv k9s /usr/local/bin && rm LICENSE && rm README.md
    
    # type k9s to start the visualization and ctl+c to exit it
    ```

1. Configure the the network settings but do not apply the changes from the remote machine (so it does not lock up the session when the IP changes). This sets the machines IP Address to the desired value as well as the DNS names. Machine IP Address for this example will be 192.168.10<number>.10 (i.e., 192.168.104.10 for level 4) with a default gateway of 192.168.10<number>.1 (i.e., 192.168.104.1 for level 4). Use your DNS servers of choice in the "addresses" section. Seeing this is a sample constrained network level 4 will use the Google DNS servers and levels 2/3 will only have their default gateway set to the DNS server.

    ```bash
    #24.04
    # NET_CONFIG_FILE=$(ls /etc/netplan/*-init.yaml)
    
    # 22.04
    NET_CONFIG_FILE=$(ls /etc/netplan/*-config.yaml)
    
    NET_CONFIG_SETTINGS="      addresses:\n        - 192.168.10<number>.10/24\n      nameservers:\n        addresses: [<dns_servers>]\n      routes:\n        - to: default\n          via: 192.168.10<number>.1" && NET_CONFIG_OLD_SETTINGS="      dhcp4: true"
    
    sudo sed -i "/${NET_CONFIG_OLD_SETTINGS}/c\\${NET_CONFIG_SETTINGS}" ${NET_CONFIG_FILE} && sudo chmod 600 ${NET_CONFIG_FILE}
    ```

1. Exit the ssh session then from the console shutdown the machine and move it to the destination network before powering it up.

    ```bash
    # Exit the ssh session
    exit
    
    timeout 10s ssh ubuntu@<IP Address> "sudo  netplan apply"
    
    # On the console 
    sudo shutdown now
    
    # Move to the location and start machine
    ```



1. Once powered up establish a connection to the new IP address to finish the K3s install and test.

    ```bash
    ssh ubuntu@192.168.10<level>
    
    # Install Kubernetes in the final spot using Air Gapped procedure
    sudo INSTALL_K3S_SKIP_DOWNLOAD=true K3S_TOKEN=SECRET ./k3s/install.sh server --secrets-encryption --cluster-init  --disable=traefik --write-kubeconfig-mode 644
    
    mkdir -p ~/.kube && cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    
    echo 'export KUBECONFIG=~/.kube/config' | tee -a ~/.bashrc && echo 'export KUBE_EDITOR="nano"' | tee -a ~/.bashrc
    
    source ~/.bashrc
    
    # Proceed after the following shows a Status of ready
    kubectl get nodes
    ```

    ![Screenshot of kubectl get nodes showing cluster ready](./images/kubectl-get-nodes-ready.png)

## Completing the Jump Box Configuration

1. After all of the levels Small Form Factor Machines have been prepared and are running in their target locations.

1. Prepare the jump box by making sure the ~/.kube/config file exists

    ```bash
    # Ensure the ~/.kube/config file exists on the jump boxx
    mkdir -p ~/.kube && touch ~/.kube/config
    
    # Backup the existing config file
    cp ~/.kube/config ~/.kube/config.bak
    ```



1. Merge the Kubectl config file with a copy of the ones of the Small Form Factor Machines. Perform the following for each of the target machines.

    ```bash
    scp ubuntu@192.168.10<level>.10:~/.kube/config ./kube-config-temp
    
    sudo sed -i "s/127.0.0.1/192.168.10<level>.10/g" ./kube-config-temp && sudo sed -i "s/  name: default/  name: level<level>/g" ./kube-config-temp && sudo sed -i "s/current-context: default/current-context: level<level>/g" ./kube-config-temp && sudo sed -i "s/    cluster: default/    cluster: level<level>/g" ./kube-config-temp && sudo sed -i "s/- name: default/- name: ubuntul<level>/g" ./kube-config-temp && sudo sed -i "s/    user: default/    user: ubuntul<level>/g" ./kube-config-temp
    
    sudo chmod 644 ./kube-config-temp
    KUBECONFIG=~/.kube/config:./kube-config-temp kubectl config view --flatten > ./kube-config-temp-flat
    
    rm ~/.kube/config && mv ./kube-config-temp-flat ~/.kube/config
    
    rm ./kube-config-temp 
    ```


1. Test each of the clusters to make sure they work from the jump box

    ```bash
    # Get a list of the available contexts (should see level2, level3, and level4)
    kubectl config get-contexts
    
    # Change to another context
    kubectl config use-context level<level>
    
    # See the cluster
    kubectl get nodes
    ```
