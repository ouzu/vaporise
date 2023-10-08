#!/usr/bin/env bash

# Überprüfen, ob das Script mit genau einem Argument aufgerufen wurde
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path_to_directory>"
    exit 1
fi

# Das bereitgestellte Argument als Pfad zum übergeordneten Verzeichnis speichern
parent_directory="$1"

# Hauptfunktion zum Ausführen des Experiments im aktuellen Verzeichnis
run_experiment() {
    # Schritt 1: Setup, Start und Deploy ausführen
    nix run .#setup && nix run .#start && nix run .#deploy

    # Load-Testing nur ausführen, wenn der vorherige Schritt erfolgreich war
    if [[ $? -eq 0 ]]; then
        # Schritt 2: k6 run load/load.js ausführen
        k6 run load/load.js
    else
        echo "Error during setup/start/deploy phase."
    fi

    # Schritt 3: Stop und Teardown ausführen, unabhängig von den vorherigen Schritten
    nix run .#stop && nix run .#teardown || echo "Error during stop/teardown phase."
}

# Durch alle Unterverzeichnisse iterieren und das Experiment ausführen
for dir in "$parent_directory"/*; do
    if [ -d "$dir" ]; then
        echo "Running experiment in directory: $dir"
        cd "$dir" || { echo "Cannot change directory to $dir"; continue; }
        run_experiment
        cd - || exit
    fi
done

