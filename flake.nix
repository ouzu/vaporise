{
  description = "NixOS in MicroVMs";

  inputs.microvm.url = "github:astro/microvm.nix";
  inputs.microvm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, microvm, ... } @ allAttrs:
    let
      numOfFogNodes = allAttrs.numOfFogNodes or 1;
      numOfEdgeNodesPerFog = allAttrs.numOfEdgeNodesPerFog or  1;

      genFogNodes = builtins.map
        (n: {
          name = "fog";
          id = n + 2;
          parent = 2;
        })
        (lib.range 1 numOfFogNodes);

      genEdgeNodes = lib.flatten (builtins.map
        (fog: builtins.map
          (n: {
            name = "edge";
            id = (3 + numOfFogNodes) + ((fog.id - 4) * numOfEdgeNodesPerFog) + n;
            parent = fog.id;
          })
          (lib.range 1 numOfEdgeNodesPerFog))
        genFogNodes);

      vmData = [{ name = "cloud"; id = 2; parent = null; }] ++ genFogNodes ++ genEdgeNodes;

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

      lib = pkgs.lib;
      mod = lib.mod;

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
        if builtins.stringLength hexValue == 0 then
          "00"
        else if builtins.stringLength hexValue == 1 then
          "0" + hexValue
        else
          hexValue;

      generateVM = { name, id, parent }: {
        users.users.root.password = "";
        environment.systemPackages = with pkgs; [
          iperf
          tcpdump
          iproute2
          traceroute
          netcat
          socat
          iputils
          nmap
        ];

        services.iperf3 = {
          enable = true;
          openFirewall = true;
        };

        services.openssh = {
          enable = true;
          passwordAuthentication = true;
          permitRootLogin = "yes";
          openFirewall = true;
        };

        networking = {
          hostName = "${name}-${builtins.toString id}";
          useDHCP = false;
          interfaces."eth0".ipv4.addresses = [{
            address = "172.20.${builtins.toString (id / 256)}.${builtins.toString (mod id 256)}";
            prefixLength = 16;
          }];
          defaultGateway = "172.20.0.1";
        };

        microvm = {
          volumes = [{
            mountPoint = "/var";
            image = "var.img";
            size = 256;
          }];
          interfaces = [{
            type = "tap";
            id = "tap-${name}-${builtins.toString id}";
            mac = "02:00:00:00:${decToHex (mod (id / 256) 2560)}:${decToHex (mod id 256)}";
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
            brctl addif br0 tap-${vm.name}-${builtins.toString vm.id}
          ''
        )
        vmData);

      removeTapCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          ''
            ip link set tap-${vm.name}-${builtins.toString vm.id} down
            brctl delif br0 tap-${vm.name}-${builtins.toString vm.id}
            ip tuntap del tap-${vm.name}-${builtins.toString vm.id} mode tap
          ''
        )
        vmData);

      createTcCmds = builtins.concatStringsSep "\n" (builtins.map
        (vm:
          ''
            tc qdisc add dev tap-${vm.name}-${builtins.toString vm.id} root netem delay ${networkProperties.${vm.name}.delay} rate ${networkProperties.${vm.name}.rate}
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
            brctl addbr br0
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
        set -e

        teardown_networking() {
            echo "Tearing down the network..."

            # Flush iptables rules
            iptables -F

            ${removeTcCmds}

            ${removeTapCmds}

            # Remove the bridge
            ip link set br0 down
            brctl delbr br0
        }

        teardown_networking
      '';

      startVMsScript = mkScript ''
        #!/usr/bin/env bash
        set -e

        echo "Building VMs..."
        nix --extra-experimental-features nix-command --extra-experimental-features flakes build -j8 ${builtins.concatStringsSep " " (map (vm: ".#" + vm.name + "-" + builtins.toString vm.id) vmData)} > /var/log/build.log 2>&1

        for vm in ${builtins.concatStringsSep " " (map (vm: vm.name + "-" + builtins.toString vm.id) vmData)}; do
          echo "Starting $vm..."
          nix --extra-experimental-features nix-command --extra-experimental-features flakes run .#$vm > /var/log/$vm.log 2>&1 &
        done
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
        startVMs = {
          type = "app";
          program = "${startVMsScript}/bin/script";
        };
      };
    };
}
