{
  description = "NixOS in MicroVMs";

  inputs.microvm.url = "github:astro/microvm.nix";
  inputs.microvm.inputs.nixpkgs.follows = "nixpkgs";

  inputs.mistify.url = "github:ouzu/tinyFaaS";
  inputs.mistify.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, microvm, mistify, ... } @ allAttrs:
    let
      numOfFogNodes = 10;
      numOfEdgeNodesPerFog = 4;

      genFogNodes = builtins.map
        (n: {
          name = "fog";
          id = n + 2;
        })
        (lib.range 1 numOfFogNodes);

      genEdgeNodes = builtins.map
        (n: {
          name = "edge";
          id = n + 2 + numOfFogNodes;
        })
        (lib.range 1 (numOfFogNodes * numOfEdgeNodesPerFog));

      vmData = [{
        name = "cloud";
        id = 2;
      }] ++ genFogNodes ++ genEdgeNodes;

      networkProperties = {
        cloud = {
          delay = "100ms";
          rate = "1gbit";
        };
        fog = {
          delay = "50ms";
          rate = "500mbit";
        };
        edge = {
          delay = "10ms";
          rate = "100mbit";
        };
      };

      system = "x86_64-linux";

      pkgs = import nixpkgs { inherit system; };
      tinyFaaS = mistify.packages.${system}.tinyFaaS;

      lib = pkgs.lib;
      mod = lib.mod;

      fillLeadingZeros = s:
        let
          len = builtins.stringLength s;
        in
        if len == 0
        then "00"
        else if len == 1
        then "0${s}"
        else s;

      decToHex =
        with lib; let
          intToHex = [
            "0"
            "1"
            "2"
            "3"
            "4"
            "5"
            "6"
            "7"
            "8"
            "9"
            "a"
            "b"
            "c"
            "d"
            "e"
            "f"
          ];
          toHex' = q: a:
            if q > 0
            then
              (toHex'
                (q / 16)
                ((elemAt intToHex (mod q 16)) + a))
            else a;
        in
        v:
        let
          hexValue = toHex' v "";
        in
        fillLeadingZeros hexValue;

      networkSetupScript = pkgs.writeShellScript "setup-networking.sh" ''
          #!/usr/bin/env bash

          set -e

          log() {
              echo "[$(date)] $1" | tee -a /var/log/setup-networking.log
          }

          PATH=$PATH:${lib.makeBinPath (with pkgs; [ iproute2 gawk ])}

          MAC_ADDR=$(ip link show dev eth0 | grep ether | awk '{print $2}')
          IFS=':' read -ra ADDR <<< "$MAC_ADDR"
          NUM_OF_FOG_NODES=''${ADDR[2]}
          NUM_OF_EDGE_NODES_PER_FOG=''${ADDR[3]}
          NODE_ID=$((0x''${ADDR[4]}''${ADDR[5]}))
          if [[ "$NODE_ID" -eq 2 ]]; then
              ROLE="cloud"
          elif [[ "$NODE_ID" -gt 2 && "$NODE_ID" -le $((2 + 0x$NUM_OF_FOG_NODES)) ]]; then
              ROLE="fog"
          else
              ROLE="edge"
          fi
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

          ip addr flush dev eth0
          ip addr add $IPV4_ADDR/24 dev eth0
          ip link set eth0 up

          ip route add default via $DEFAULT_GATEWAY

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

        RegistryPort = 8082
        Host = "$IPV4_ADDR"
        EOF
        
          if [[ "$ROLE" == "fog" ]]; then
              echo "ParentAddress = \"172.20.0.2:8082\"" >> /var/lib/mistify/config.toml
          elif [[ "$ROLE" == "edge" ]]; then
              PARENT_ID=$(( (NODE_ID - 2 - 1) / NUM_OF_EDGE_NODES_PER_FOG + 2 ))
              PARENT_FOG_NODE_IP="172.20.$((PARENT_ID / 256)).$((PARENT_ID % 256))"
              echo "ParentAddress = \"$PARENT_FOG_NODE_IP:8082\"" >> /var/lib/mistify/config.toml
          fi
      '';

      mistifyStartScript = pkgs.writeShellScript "start-mistify.sh" ''
        #!/usr/bin/env bash
        PATH=$PATH:${lib.makeBinPath [tinyFaaS]}
        mistify config.toml
      '';

      tinyFaaSStartScript = pkgs.writeShellScript "start-tinyFaaS.sh" ''
        #!/usr/bin/env bash
        PATH=$PATH:${lib.makeBinPath [tinyFaaS]}
        ln -s ${tinyFaaS}/share/tinyFaaS/runtimes ./runtimes
        export DOCKER_API_VERSION=1.41
        manager config.toml
      '';

      generateVM = { name, id }: {
        users.users.root.password = "";
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

        system.stateVersion = "23.11";

        microvm = {
          interfaces = [{
            type = "tap";
            id = "tap-${name}-${builtins.toString id}";
            mac =
              let
                nFog = fillLeadingZeros (builtins.toString numOfFogNodes);
                nEdge = fillLeadingZeros (builtins.toString numOfEdgeNodesPerFog);
                id1 = decToHex (mod (id / 256) 256);
                id2 = decToHex (mod id 256);
              in
              "02:00:${nFog}:${nEdge}:${id1}:${id2}";
          }];
          socket = "/tmp/${builtins.toString id}-${name}.socket";
          hypervisor = "firecracker";
        };
      };

      generateVMs = vmData: builtins.listToAttrs (map
        (vm: {
          name = "${vm.name}-${builtins.toString vm.id}";
          value = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              microvm.nixosModules.microvm
              (generateVM vm)
            ];
          };
        })
        vmData
      );

      generatePackages = vmData: builtins.listToAttrs (map
        (vm: {
          name = "${vm.name}-${builtins.toString vm.id}";
          value =
            let
              config = self.nixosConfigurations."${vm.name}-${builtins.toString vm.id}".config;
            in
            config.microvm.runner.firecracker;
        })
        vmData
      );

      mkScript = content: pkgs.writeShellScriptBin "script" content;

      createTapCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          ''
            echo "Setting up tap interface for ${vm.name}-${builtins.toString vm.id}..."
            ip tuntap add tap-${vm.name}-${builtins.toString vm.id} mode tap user $(whoami)
            ip link set tap-${vm.name}-${builtins.toString vm.id} up
            ip link set dev tap-${vm.name}-${builtins.toString vm.id} master br0
          ''
        )
        vmData);

      removeTapCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          ''
            ip link set tap-${vm.name}-${builtins.toString vm.id} down
            ip tuntap del tap-${vm.name}-${builtins.toString vm.id} mode tap
          ''
        )
        vmData);

      createTcCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          let
            device = "tap-${vm.name}-${builtins.toString vm.id}";
            delay = networkProperties.${vm.name}.delay;
            rate = networkProperties.${vm.name}.rate;
          in
          ''
            tc qdisc add dev ${device} root netem delay ${delay} rate ${rate}
          ''
        )
        vmData);

      removeTcCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          ''
            tc qdisc del dev tap-${vm.name}-${builtins.toString vm.id} root
          ''
        )
        vmData);

      setupScript = mkScript ''
        #!/usr/bin/env bash
        set -e

        setup_networking() {
            # Create bridge
            echo "Setting up bridge interface..."
            ip link add name br0 type bridge
            ip addr add 172.20.0.1/24 dev br0
            ip link set br0 up

            ${createTapCmds}

            ${createTcCmds}

            # Get the main interface device
            DEVICE_NAME=$(ip route | awk '/default/ { print $5 }')

            # Enable packet forwarding
            echo 1 > /proc/sys/net/ipv4/ip_forward
            iptables -t nat -A POSTROUTING -o $DEVICE_NAME -j MASQUERADE
            iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
            iptables -A FORWARD -i br0 -o $DEVICE_NAME -j ACCEPT
        }

        setup_networking
      '';

      teardownScript = mkScript ''
        #!/usr/bin/env bash

        teardown_networking() {
            echo "Tearing down the network..."

            # Flush iptables rules
            iptables -F

            ${removeTcCmds}

            ${removeTapCmds}

            # Remove the bridge
            ip link set br0 down
            ip link del br0
        }

        teardown_networking
      '';

      startVMsScript =
        let
          nixCmd = "nix --extra-experimental-features nix-command --extra-experimental-features flakes";
          packages = map (vm: ".#" + vm.name + "-" + builtins.toString vm.id) vmData;
          names = map (vm: vm.name + "-" + builtins.toString vm.id) vmData;
        in
        mkScript ''
          #!/usr/bin/env bash
          set -e

          echo "Building first VM..."
          ${nixCmd} build .#cloud-2
          
          for vm in ${builtins.concatStringsSep " " names}; do
            echo "Starting $vm..."
            ${nixCmd} run .#$vm > /var/log/$vm.log 2>&1 &
            sleep 1
          done
        '';

      mapVMData = builtins.map
        (vm: {
          inherit vm;
          divResult = toString (builtins.div vm.id 256);
          modResult = toString (lib.mod vm.id 256);
        })
        vmData;


      stopVMsScript = mkScript ''
        #!/usr/bin/env bash

        pkill firecracker
      '';

      loginScript = mkScript ''
        #!/usr/bin/env bash

        if [ $# -ne 1 ]; then
            echo "Usage: $0 <hostname-or-ip>"
            exit 1
        fi

        HOST="$1"

        PASSWORD=""
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST"
      '';

    in
    {
      nixosConfigurations = generateVMs vmData;
      packages.${system} = generatePackages vmData;

      apps.${system} = {
        setup = {
          type = "app";
          program = "${setupScript}/bin/script";
        };
        teardown = {
          type = "app";
          program = "${teardownScript}/bin/script";
        };
        start = {
          type = "app";
          program = "${startVMsScript}/bin/script";
        };
        stop = {
          type = "app";
          program = "${stopVMsScript}/bin/script";
        };
        login = {
          type = "app";
          program = "${loginScript}/bin/script";
        };
      };
    };
}
