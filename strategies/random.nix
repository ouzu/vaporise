{ pkgs, lib, mistifyStrategy, ... }:
let
  mistifyStrategy = "random";

  # this is the node setup script, it initializes the microvm
  networkSetupScript = with pkgs; writeShellScript "setup-networking.sh" ''
      #!/usr/bin/env bash

      set -e

      log() {
          echo "[$(date)] $1" | tee -a /var/log/setup-networking.log
      }

      PATH=$PATH:${lib.makeBinPath [ iproute2 gawk ]}

      # Get the MAC address
      MAC_ADDR=$(ip link show dev eth0 | grep ether | awk '{print $2}')
      IFS=':' read -ra ADDR <<< "$MAC_ADDR"

      # extract the parameters from the MAC address
      NUM_OF_FOG_NODES=''${ADDR[2]}
      NUM_OF_EDGE_NODES_PER_FOG=''${ADDR[3]}
      NODE_ID=$((0x''${ADDR[4]}''${ADDR[5]}))

      # determine the node type
      if [[ "$NODE_ID" -eq 2 ]]; then
          ROLE="cloud"
      elif [[ "$NODE_ID" -gt 2 && "$NODE_ID" -le $((2 + $NUM_OF_FOG_NODES)) ]]; then
          ROLE="fog"
      else
          ROLE="edge"
      fi

      # generate the node parameters
      HOSTNAME="''${ROLE}-''${NODE_ID}"
      IPV4_ADDR="172.20.$((NODE_ID / 256)).$((NODE_ID % 256))"
      DEFAULT_GATEWAY="172.20.0.1"

      log "MAC_ADDR: $MAC_ADDR"
      log "NUM_OF_FOG_NODES: $NUM_OF_FOG_NODES"
      log "NUM_OF_EDGE_NODES_PER_FOG: $NUM_OF_EDGE_NODES_PER_FOG"
      log "NODE_ID: $NODE_ID"
      log "ROLE: $ROLE"
      log "HOSTNAME: $HOSTNAME"
      log "IPV4_ADDR: $IPV4_ADDR"

      # configure the network
      ip addr flush dev eth0
      ip addr add $IPV4_ADDR/24 dev eth0
      ip link set eth0 up

      ip route add default via $DEFAULT_GATEWAY

      # create the mistify config file
      mkdir -p /var/lib/mistify

      cat > /var/lib/mistify/config.toml <<EOF
    ConfigPort = 8080
    RProxyConfigPort = 8081
    RProxyListenAddress = "0.0.0.0"
    RProxyBin = "rproxy"

    COAPPort = 5683
    HTTPPort = 80
    GRPCPort = 9000

    Backend = "docker"
    ID = "$HOSTNAME"

    Mode = "$ROLE"

    MistifyStrategy = "${mistifyStrategy}"

    RegistryPort = 8082
    Host = "$IPV4_ADDR"
    EOF
        
      if [[ "$ROLE" == "fog" ]]; then
          echo "ParentAddress = \"172.20.0.2:8082\"" >> /var/lib/mistify/config.toml
      elif [[ "$ROLE" == "edge" ]]; then
          ASSIGNED_EDGES=$(( NODE_ID - NUM_OF_FOG_NODES - 2 ))
          PARENT_ID=$(( 3 + (ASSIGNED_EDGES - 1) / NUM_OF_EDGE_NODES_PER_FOG ))
          PARENT_FOG_NODE_IP="172.20.$((PARENT_ID / 256)).$((PARENT_ID % 256))"
          echo "ParentAddress = \"$PARENT_FOG_NODE_IP:8082\"" >> /var/lib/mistify/config.toml
      fi
  '';

  # this is the mistify start script, it starts the mistify service
  mistifyStartScript = with pkgs; writeShellScript "start-mistify.sh" ''
    #!/usr/bin/env bash
    PATH=$PATH:${lib.makeBinPath [tinyFaaS]}
    export LOG_LEVEL=debug
    mistify config.toml
  '';

  # this is the tinyFaaS start script, it starts the tinyFaaS service
  tinyFaaSStartScript = with pkgs; writeShellScript "start-tinyFaaS.sh" ''
    #!/usr/bin/env bash
    PATH=$PATH:${lib.makeBinPath [tinyFaaS]}
    ln -s ${tinyFaaS}/share/tinyFaaS/runtimes ./runtimes
    export DOCKER_API_VERSION=1.41
    manager config.toml
  '';
in
{
  users.users.root = {
    password = "";
    shell = pkgs.zsh;
  };

  programs.zsh.enable = true;

  programs.starship = {
    enable = true;
    settings = {
      format = "$localip$directory$character";
    };
  };

  environment.systemPackages = with pkgs; [
    iperf
    iproute2
    nmap
    tinyFaaS
  ];

  services.iperf3 = {
    enable = true;
    openFirewall = true;
  };

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  networking = {
    hostName = "vm";
    useDHCP = false;
    interfaces."eth0".ipv4.addresses = [{
      address = "172.21.0.1";
      prefixLength = 16;
    }];
    defaultGateway = "172.20.0.1";
    nameservers = [ "1.1.1.1" ];
    firewall.allowedTCPPorts = [ 80 8080 8081 8082 9000 ];
    firewall.allowedUDPPorts = [ 5683 ];
  };

  systemd.services.setup-network = {
    description = "Setup networking based on MAC address";
    after = [ "network-pre.target" ];
    before = [ "sshd.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = "yes";
      ExecStart = "${networkSetupScript}";
    };
  };

  virtualisation.docker.enable = true;

  systemd.services.mistify = {
    description = "Mistify";
    after = [ "network-pre.target" "setup-network.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${mistifyStartScript}";
      WorkingDirectory = "/var/lib/mistify";
    };
  };

  systemd.services.tinyFaaS =
    {
      description = "TinyFaaS";
      after = [ "network-pre.target" "docker.service" "mistify.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${tinyFaaSStartScript}";
        WorkingDirectory = "/var/lib/mistify";
      };
    };

  system.stateVersion = "23.05";
}
