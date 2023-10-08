#!/usr/bin/env bash

STRATEGIES_DIR="strategies"
LOADS_DIR="loads"
EXPERIMENTS_DIR="experiments"

mkdir -p "$EXPERIMENTS_DIR"

for strategy_file in "$STRATEGIES_DIR"/*.nix; do
    
    strategy_name="${strategy_file##*/}"
    strategy_name="${strategy_name%.nix}"
    
    for load_file in "$LOADS_DIR"/*.js; do
        
        load_name="${load_file##*/}"
        load_name="${load_name%.js}"
        
        experiment_dir="$EXPERIMENTS_DIR/$load_name-$strategy_name"
        mkdir -p "$experiment_dir"
        
        cp "$load_file" "$experiment_dir/load.js"
        cp "$strategy_file" "$experiment_dir/microvm.nix"
        cp "cloud.toml" "$experiment_dir"
        cp "flake.nix" "$experiment_dir"
        cp "flake.lock" "$experiment_dir"
    done
done
