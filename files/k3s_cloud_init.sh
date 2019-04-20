#!/bin/bash

# These should be substituted by Terrafrom template
CLUSTER_SECRET="${CLUSTER_SECRET}"
IS_SERVER="${IS_SERVER}"
ZT_STATIC_IP="${ZT_STATIC_IP}"

%{ if IS_SERVER ~}
ZT_SERVER_IP=""
EXT_IP="${EXT_IP}"
%{ else }
ZT_SERVER_IP="${ZT_SERVER_IP}"
EXT_IP=""
%{ endif ~}

ZT_API_KEY="${ZT_API_KEY}"
ZT_NET="${ZT_NET}"

%{ if IS_SERVER ~}
echo "Provisioning server"
%{ else }
echo "Provisioning agent"
%{ endif ~}


if [ -z "$CLUSTER_SECRET" ]; then
    echo "ERROR: No cluster secret"
    exit 1
fi
if [ -z "$ZT_STATIC_IP" ]; then
    echo "ERROR: No ZeroTier Static IP"
    exit 1
fi
if [ -z "$ZT_API_KEY" ]; then
    echo "ERROR: No ZeroTier API Key"
    exit 1
fi
if [ -z "$ZT_NET" ]; then
    echo "ERROR: No ZeroTier Network ID"
    exit 1
fi
if [ -z "$ZT_SERVER_IP" -a $IS_SERVER != 1 ]; then
    echo "ERROR: No Server IP"
    exit 1
fi
if [ -z "$EXT_IP" -a $IS_SERVER == 1 ]; then
    echo "ERROR: No Server IP"
    exit 1
fi

SYSTEMD_SERVER=$(cat <<-'EOF'
	[Unit]
	Description=Lightweight Kubernetes
	Documentation=https://k3s.io
	After=network.target

	[Service]
	ExecStartPre=-/sbin/modprobe br_netfilter
	ExecStartPre=-/sbin/modprobe overlay
	ExecStart=/usr/local/bin/k3s server --disable-agent --flannel-iface __IFACE__ --cluster-secret __CLUSTER_SECRET__ --node-ip __IP_ADDR__ --no-deploy traefik --no-deploy=servicelb --bind-address __IP_ADDR__ --tls-san __EXT_IP__
	KillMode=process
	Delegate=yes
	LimitNOFILE=infinity
	LimitNPROC=infinity
	LimitCORE=infinity
	TasksMax=infinity

	[Install]
	WantedBy=multi-user.target
EOF
)

SYSTEMD_AGENT=$(cat <<-'EOF'
	[Unit]
	Description=Lightweight Kubernetes
	Documentation=https://k3s.io
	After=network.target

	[Service]
	ExecStartPre=-/sbin/modprobe br_netfilter
	ExecStartPre=-/sbin/modprobe overlay
	ExecStart=/usr/local/bin/k3s agent --flannel-iface __IFACE__ --cluster-secret __CLUSTER_SECRET__ --node-ip __IP_ADDR__ --server https://__ZT_SERVER_IP__:6443 
	KillMode=process
	Delegate=yes
	LimitNOFILE=infinity
	LimitNPROC=infinity
	LimitCORE=infinity
	TasksMax=infinity

	[Install]
	WantedBy=multi-user.target
EOF
)

export FLASH_KERNEL_SKIP=1 

if [ ! -e /usr/local/bin/k3s ]; then
    echo "Downloading k3s"
    wget https://github.com/rancher/k3s/releases/download/v0.4.0/k3s-armhf -O /usr/local/bin/k3s
    ln -s /usr/local/bin/k3s /usr/local/bin/k3s-server
    ln -s /usr/local/bin/k3s /usr/local/bin/k3s-agent
fi

echo "Make k3s executable"
chmod +x /usr/local/bin/k3s

if [ ! -e /usr/bin/gpg ]; then
    echo "Instal gpg"
    apt install -y gpg
fi

if [ ! -e /usr/sbin/zerotier-cli ]; then
    echo "Install ZeroTier"
    wget -qO - 'https://raw.githubusercontent.com/zerotier/download.zerotier.com/master/htdocs/contact%40zerotier.com.gpg' | gpg --import && \
    if z=$(wget -qO - 'https://install.zerotier.com/' | gpg); then echo "$z" | bash; fi
fi

echo "Joing ZeroTier network"
ip a | grep '[0-9]*: zt' > /dev/null
if [[ $? -ne 0 ]]; then
    zerotier-cli join $ZT_NET

    echo "INFO: Waiting 10 seconds for the ZeroTier join to work"
    sleep 10
    NODE_ID=$(zerotier-cli info | awk '{print $3}')

    echo "{ \"name\": \"$(hostname)\", \"config\": { \"authorized\": true, \"ipAssignments\": [\"$ZT_STATIC_IP\"] } }" | curl -X POST -H "Authorization: Bearer $ZT_API_KEY" -d @- "https://my.zerotier.com/api/network/$ZT_NET/member/$NODE_ID"

    if [ $? -ne 0 ]; then
        echo "ERROR: Unable to join network"
        exit 1
    fi
fi

echo "Get ZT interface and IP"
IFACE=$(ip a | grep '^[0-9]*: zt' | sed 's/^[0-9]*: \([^:]*\):.*$/\1/g')
echo "Interface: $IFACE"
IP_ADDR=$(ip a sho dev $IFACE | grep '^    inet ' | sed 's/^    inet \([^\/]*\)\/.*$/\1/g')
echo "IP: $IP_ADDR"
while [ -z "$IP_ADDR" ]; do
    echo "IP Address not set yet. Waiting."
    sleep 30
    IP_ADDR=$(ip a sho dev $IFACE | grep '^    inet ' | sed 's/^    inet \([^\/]*\)\/.*$/\1/g')
    echo "IP: $IP_ADDR"
done

if [[ $IS_SERVER -eq 1 ]]; then
    echo "INFO: Adding k3-server.service to systemd"
    SYSTEMD_SERVER="$(printf "$SYSTEMD_SERVER" | sed "s/__IFACE__/$IFACE/g")"
    SYSTEMD_SERVER="$(printf "$SYSTEMD_SERVER" | sed "s/__CLUSTER_SECRET__/$CLUSTER_SECRET/g")"
    SYSTEMD_SERVER="$(printf "$SYSTEMD_SERVER" | sed "s/__EXT_IP__/$EXT_IP/g")"
    SYSTEMD_SERVER="$(printf "$SYSTEMD_SERVER" | sed "s/__IP_ADDR__/$IP_ADDR/g")"
    echo "$SYSTEMD_SERVER" > /etc/systemd/system/k3s-server.service
    echo "INFO: Enabling k3s-server"
    systemctl enable k3s-server
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Unable to enable k3s-server"
        exit 1
    fi
    systemctl start k3s-server
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Unable to start k3s-server"
        exit 1
    fi

    echo "Waiting 30 seconds..."
    sleep 30
    echo "INFO: Checking k3s-server is active...."
    systemctl is-active --quiet k3s-server
    while [[ $? -ne 0 ]]; do
        sleep 30
        echo "INFO: Checking k3s-server is active...."
        systemctl is-active --quiet k3s-server
    done

    ZT_SERVER_IP=$IP_ADDR
fi

echo "INFO: Adding k3-agent.service to systemd"
SYSTEMD_AGENT="$(printf "$SYSTEMD_AGENT" | sed "s/__IFACE__/$IFACE/g")"
SYSTEMD_AGENT="$(printf "$SYSTEMD_AGENT" | sed "s/__CLUSTER_SECRET__/$CLUSTER_SECRET/g")"
SYSTEMD_AGENT="$(printf "$SYSTEMD_AGENT" | sed "s/__IP_ADDR__/$IP_ADDR/g")"
SYSTEMD_AGENT="$(printf "$SYSTEMD_AGENT" | sed "s/__ZT_SERVER_IP__/$ZT_SERVER_IP/g")"
echo "$SYSTEMD_AGENT" > /etc/systemd/system/k3s-agent.service
echo "INFO: Enabling k3s-agent"
systemctl enable k3s-agent
if [[ $? -ne 0 ]]; then
    echo "ERROR: Unable to enable k3s-agent"
    exit 1
fi
systemctl start k3s-agent
if [[ $? -ne 0 ]]; then
    echo "ERROR: Unable to start k3s-agent"
    exit 1
fi

echo "Waiting 30 seconds..."
sleep 30
echo "INFO: Checking k3s-agent is active...."
systemctl is-active --quiet k3s-agent
while [[ $? -ne 0 ]]; do
    sleep 30
    echo "INFO: Checking k3s-agent is active...."
    systemctl is-active --quiet k3s-agent
done

