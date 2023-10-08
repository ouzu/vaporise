{
  description = "NixOS in MicroVMs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/release-23.05";
  
  inputs.microvm.url = "github:astro/microvm.nix";
  inputs.microvm.inputs.nixpkgs.follows = "nixpkgs";

  inputs.mistify.url = "github:ouzu/tinyFaaS";
  inputs.mistify.inputs.nixpkgs.follows = "nixpkgs";

  inputs.tinyFaaS-cli.url = "github:ouzu/tinyFaaS-cli";
  inputs.tinyFaaS-cli.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, microvm, mistify, tinyFaaS-cli, ... } @ allAttrs:
    let
      # how many fog nodes to create
      numOfFogNodes = 16;

      # how many edge nodes to create per fog node
      numOfEdgeNodesPerFog = 6;

      # network properties for each node type
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
          delay = "1ms";
          rate = "100mbit";
        };
      };

      system = "x86_64-linux";

      tinyFaaS = mistify.packages.${system}.tinyFaaS;
      tfcli = tinyFaaS-cli.packages.${system}.tinyFaaS-cli;

      pkgs = import nixpkgs {
        inherit system;
        config.permittedInsecurePackages = [
          "python3.10-requests-2.28.2"
          # who doesn't love using insecure cryptography libraries?
          "python3.10-cryptography-40.0.2"
          "python3.10-cryptography-40.0.1"
        ];
      };

      lib = pkgs.lib;
      mod = lib.mod;

      # build the list of fog nodes
      genFogNodes = builtins.map
        (n: {
          name = "fog";
          id = n + 2;
        })
        (lib.range 1 numOfFogNodes);

      # build the list of edge nodes
      genEdgeNodes = builtins.map
        (n: {
          name = "edge";
          id = n + 2 + numOfFogNodes;
        })
        (lib.range 1 (numOfFogNodes * numOfEdgeNodesPerFog));

      # build the list of all nodes
      vmData = [{
        name = "cloud";
        id = 2;
      }] ++ genFogNodes ++ genEdgeNodes;

      # fill leading zeros, used for MAC address generation
      fillLeadingZeros = s:
        let
          len = builtins.stringLength s;
        in
        if len == 0
        then "00"
        else if len == 1
        then "0${s}"
        else s;

      # convert decimal to hex
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

      # this is the VM generation function, it generates the NixOS configuration for a VM
      generateVM = { name, id }: {
        imports = [
          ./microvm.nix
        ];

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
          volumes = [{
            image = "/tmp/vaporise/${builtins.toString id}-${name}-var-lib.img";
            mountPoint = "/var/lib";
            size = 2048;
          }];
          socket = "/tmp/vaporise/${builtins.toString id}-${name}.socket";
          hypervisor = "firecracker";
        };
      };

      # generate the NixOS configurations for all VMs
      generateVMs = vmData: builtins.listToAttrs (map
        (vm: {
          name = "${vm.name}-${builtins.toString vm.id}";
          value = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              (
                { pkgs, ... }:
                {
                  nixpkgs.overlays = [
                    (self: super: {
                      tinyFaaS = tinyFaaS;
                    })
                  ];
                }
              )
              microvm.nixosModules.microvm
              (generateVM vm)
            ];
          };
        })
        vmData
      );

      # generate the packages for all VMs
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

      # helper function to generate a shell script
      mkScript = content: pkgs.writeShellScriptBin "script" content;

      # script for creating the TAP interfaces on the host
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

      # script for deleting the TAP interfaces on the host
      removeTapCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          ''
            ip link set tap-${vm.name}-${builtins.toString vm.id} down
            ip tuntap del tap-${vm.name}-${builtins.toString vm.id} mode tap
          ''
        )
        vmData);

      # script for applying network shaping on the host
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

      # script for removing network shaping on the host
      removeTcCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          ''
            tc qdisc del dev tap-${vm.name}-${builtins.toString vm.id} root
          ''
        )
        vmData);

      # script for setting up the network on the host
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

      # script for tearing down the network on the host
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

      # script for starting the VMs
      startVMsScript =
        let
          nixCmd = "nix --extra-experimental-features nix-command --extra-experimental-features flakes";
          packages = map (vm: ".#" + vm.name + "-" + builtins.toString vm.id) vmData;
          names = map (vm: vm.name + "-" + builtins.toString vm.id) vmData;
        in
        mkScript ''
          #!/usr/bin/env bash
          set -e

          mkdir -p /tmp/vaporise

          echo "Building first VM..."
          ${nixCmd} build .#cloud-2
          
          for vm in ${builtins.concatStringsSep " " names}; do
            echo "Starting $vm..."
            ${nixCmd} run .#$vm > /var/log/$vm.log 2>&1 &
            sleep 0.3
          done
        '';

      # script for stopping the VMs
      stopVMsScript = mkScript ''
        #!/usr/bin/env bash

        pkill firecracker

        rm -rf /tmp/vaporise
      '';

      # script for logging into a VM
      loginScript = mkScript ''
        #!/usr/bin/env bash

        if [ $# -ne 1 ]; then
            echo "Usage: $0 <hostname-or-ip>"
            exit 1
        fi

        HOST="$1"

        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$HOST"
      '';

      # script for capturing traffic using tcpdump
      captureScript = mkScript ''
        #!/usr/bin/env bash

        ${pkgs.tcpdump}/bin/tcpdump -w ./capture.pcap -i br0 "(src net 172.20.0.0/24) and (dst net 172.20.0.0/24)"
      '';

      # script for deploying functions
      deployScript =
        let
          fns = [
            "dd"
            "matmul"
            "iperf"
          ];

          deployCommand = (fn:
            ''${tfcli}/bin/tinyFaaS-cli --config cloud.toml upload ${tinyFaaS}/share/tinyFaaS/fns/${fn} "${fn}" "python" 1''
          );
        in
        mkScript ''
          #!/usr/bin/env bash

          ${builtins.concatStringsSep "\n" (map deployCommand fns)}
        '';

    in
    {
      nixosConfigurations = generateVMs vmData // {
        default = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            <nixpkgs/nixos/modules/virtualisation/google-compute-image.nix>
            {
              imports = [
                ./host.nix
              ];
            }
          ];
        };
      };
      packages.${system} = generatePackages vmData;

      devShell.${system} = with pkgs; mkShell {
        name = "vaporise-shell";
        buildInputs = [
          tfcli
          tcpdump
          nixopsUnstable
          google-cloud-sdk
          k6
        ];
      };

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
        capture = {
          type = "app";
          program = "${captureScript}/bin/script";
        };
        deploy = {
          type = "app";
          program = "${deployScript}/bin/script";
        };
      };
    };
}
