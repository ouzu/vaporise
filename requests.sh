#!/usr/bin/env bash

total_iterations=5000

print_progress_bar() {
    local progress="$1"
    local total="$2"
    printf "\r%d%%" $(($progress * 100 / $total))
}

for i in $(seq 1 $total_iterations); do
    # Generate a random number X between 19 and 130
    X=$(( 19 + $RANDOM % 112 ))

    # Execute the xh command
    xh "172.20.0.$X/matmul" --ignore-stdin -- n=1000 metadata= &

    # Wait for a random time
    sleep $(echo "scale=4; $RANDOM/32767*0.02" | bc)

    # Print progress bar
    print_progress_bar $i $total_iterations
done

echo ""