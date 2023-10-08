#!/usr/bin/env bash

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path_to_directory>"
    exit 1
fi

parent_directory="$1"

run_experiment() {
    nix run .#setup && nix run .#start && nix run .#deploy

    if [[ $? -eq 0 ]]; then
        k6 run --out csv=results.csv load.js
    else
        echo "Error during setup/start/deploy phase."
    fi

    nix run .#stop && nix run .#teardown || echo "Error during stop/teardown phase."
}

for dir in "$parent_directory"/*; do
    if [ -d "$dir" ]; then
        echo "Running experiment in directory: $dir"
        cd "$dir" || { echo "Cannot change directory to $dir"; continue; }
        run_experiment
        cd - || exit
    fi
done

