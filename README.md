# Usage

For running the simulation, a NixOS Host capable of nested virtualisation is required.

To set up a NixOS image on GCP, [we follwed this guide](https://web.archive.org/web/20231006144432/https://nixos.wiki/wiki/Install_NixOS_on_GCE).

## Host Setup
- Create a GCP instance
- `nix-shell -p git`
- `git clone https://github.com/ouzu/vaporise.git`
- `cd vaporise`
- `nixos-rebuild switch --use-remote-sudo --impure --flake .#default`
- `reboot`

## Running the Experiment
