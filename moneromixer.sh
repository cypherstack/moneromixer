#!/bin/bash

# Monero Mixer
#
# A churning script. Requires `jq` and optionally `qrencode`. Uses the Monero wallet RPC to create,
# restore, and churn wallets. Offers an optional interactive mode for manual input of mnemonics and
# restore heights.
#
# Usage:
# - Configure the script parameters below.
# - Make the script executable if needed:
#   chmod +x moneromixer.sh
# - Run the script:
#   ./moneromixer.sh
#
# Available flags:
# -h, --help: Display the script help and exit.
# -v, --verbose: Enable verbose mode for additional output.
# -i, --interactive: Enable interactive mode for manual input of mnemonics and restore heights.
# -t, --test: Run integration tests prior to entering the main workflow.  Exits if any tests fail.
# -s, --simulate: Simulate the workflow without making any RPC calls.

# Configuration parameters.
RPC_PORT=18082                   # [port] The RPC port for the Monero wallet RPC server.
RPC_HOST="127.0.0.1"             # [host] The hostname or IP address for the Monero wallet RPC.
RPC_USERNAME="username"          # [username] Your RPC username.  Used for RPC authentication.
RPC_PASSWORD="password"          # [password] Your RPC password.  Used for RPC authentication.

STATE_FILE="./state.log"        # [file] Path to the file where the churning process state is logged.
SIM_STATE_FILE="./simstate.log" # [file] Path to a separate state file used in simulation mode.
DEFAULT_PASSWORD="0"            # [password] Default wallet password.  Set to '0' to prompt for input.
SWEEP_ADDRESS=""                # [address] The address to which to sweep at the end of the workflow.
GENERATE_QR=false               # [boolean] Generate QR codes for addresses?  Requires qrencode.
SELF_RESTART=false              # [boolean] Loop the script after completion?

MIN_ROUNDS=5                   # [rounds] Minimum number of churning rounds per session.
MAX_ROUNDS=50                  # [rounds] Maximum number of churning rounds per session.
NUM_SESSIONS=3                 # [sessions] Number of churning sessions to perform. Set to 0 for infinite.
MIN_DELAY=1                    # [seconds] Minimum delay between transactions.
MAX_DELAY=3600                 # [seconds] Maximum delay between transactions.

VERBOSE=false                  # [boolean] Print extra RPC request details?
INTERACTIVE_MODE=false         # [boolean] Prompt for manual input of mnemonics?
TEST_INTEGRATION=false         # [boolean] Run tests and exit without entering workflow on failure?
SIMULATE_WORKFLOW=false        # [boolean] Simulate the workflow without using real RPC requests?

RESTORE_HEIGHT_OFFSET=1000     # [height] The offset to apply to the restore height when restoring wallets.

# Check for required dependencies.
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is not installed."
    echo "Please install it by running:"
    echo "sudo apt-get install jq"
    exit 1
fi

if [ "$GENERATE_QR" = true ] && ! command -v qrencode >/dev/null 2>&1; then
    echo "Error: 'qrencode' is not installed but required for QR code generation."
    echo "Please install it by running:"
    echo "sudo apt-get install qrencode"
    exit 1
fi

# Parse command-line arguments.
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Please open the script for more information and to configure the parameters."
            echo
            echo "Default configuration:"
            echo "By default, this script will generate wallets, wait for unlocked balance, and churn funds."
            echo "You can configure the script parameters in the script itself."
            echo
            echo "Interactive mode: -i, --interactive"
            echo "You can also run the script with the -i or --interactive flag to enable interactive mode."
            echo "In interactive mode you can enter your own mnemonics and restore heights."
            echo
            echo "QR code generation: -q, --qr"
            echo "You can enable QR code generation for addresses by using the -q or --qr flag."
            echo "QR code generation requires the 'qrencode' package to be installed."
            echo
            echo "Simulation mode: -s, --simulate"
            echo "You can run the script in simulation mode by using the -s or --simulate flag."
            echo "In simulation mode, the script will simulate the workflow without making any RPC calls."
            echo
            echo "Integration tests: -t, --test"
            echo "You can run integration tests by using the -t or --test flag."
            echo "This will test RPC connectivity, wallet creation, opening, and other RPC calls."
            echo
            echo "Verbose mode: -v, --verbose"
            echo "You can enable verbose mode by using the -v or --verbose flag."
            echo "Verbose mode will print additional details for each RPC request."
            exit 1
            ;;
        -i|--interactive)
            INTERACTIVE_MODE=true
            shift # Remove the argument from processing.
            ;;
        -q|--qr)
            GENERATE_QR=true
            shift
            ;;
        -s|--simulate)
            SIMULATE_WORKFLOW=true
            shift
            ;;
        -t|--test)
            TEST_INTEGRATION=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [-i|--interactive]"
            exit 1
            ;;
    esac
done

# Choose the appropriate state file based on simulation mode.
if [ "$SIMULATE_WORKFLOW" = true ]; then
    STATE_FILE="$SIM_STATE_FILE"
fi

# Display the script introduction and overview.
script_introduction() {
    echo "Monero Mixer v2"
    echo
    echo "This script automates Monero churn as a potential countermeasure for black marble attacks."
    echo "You can provide your own wallet mnemonics, set restore heights, and configure a final sweep address."
    echo
    echo "Follow the prompts to enter your wallet mnemonics and restore heights."
    echo "Leave the input blank to indicate that you are done entering mnemonics."
    echo "Finally, you can optionally set a final sweep address."
    echo
}

# Function to enable interactive mode.
interactive_mode() {
    script_introduction

    # Initialize empty arrays for mnemonics and restore heights.
    local mnemonics=()
    local restore_heights=()

    while true; do
        # Prompt for mnemonic.
        read -rp "Enter mnemonic (leave blank to finish): " mnemonic
        if [ -z "$mnemonic" ]; then
            break
        fi

        # Validate mnemonic length (should be 25 words).
        local word_count
        word_count=$(echo "$mnemonic" | wc -w)
        if [ "$word_count" -ne 25 ]; then
            echo "Error: Mnemonic must be exactly 25 words. You entered $word_count words."
            exit 1
        fi

        # Prompt for restore height.
        read -rp "Enter restore height for this mnemonic (default: 0): " restore_height
        restore_height=${restore_height:-0}

        # Add mnemonic and restore height to the arrays.
        mnemonics+=("$mnemonic")
        restore_heights+=("$restore_height")
    done

    # Prompt for final sweep address.
    read -rp "Enter final sweep address (leave blank for no sweep): " SWEEP_ADDRESS

    # Generate wallets using the provided mnemonics and restore heights.
    generate_wallets_from_mnemonics "${mnemonics[@]}" "${restore_heights[@]}"
}

# Generate wallets using provided mnemonics and restore heights.
generate_wallets_from_mnemonics() {
    local mnemonics=("$@")
    local restore_heights=("${mnemonics[@]:${#mnemonics[@]}/2}")
    mnemonics=("${mnemonics[@]:0:${#mnemonics[@]}/2}")

    for ((i = 0; i < ${#mnemonics[@]}; i++)); do
        local wallet_name
        wallet_name=$(generate_wallet_name)
        local password="$DEFAULT_PASSWORD"
        local address
        local mnemonic="${mnemonics[i]}"
        local restore_height="${restore_heights[i]}"

        # Restore the wallet using the mnemonic and restore height.
        if [ "$SIMULATE_WORKFLOW" = true ]; then
            address="SimulatedWalletAddress_$i"
            echo "Simulating wallet creation with mnemonic: $mnemonic"
        else
            rpc_request false "restore_deterministic_wallet" '{
                "restore_height": '"$restore_height"',
                "filename": "'"$wallet_name"'",
                "seed": "'"$mnemonic"'",
                "password": "'"$password"'",
                "language": "English"
            }'

            # Open the wallet to get the address.
            rpc_request false "open_wallet" '{
                "filename": "'"$wallet_name"'",
                "password": "'"$password"'"
            }'

            # Get the wallet address.
            address=$(rpc_request false "get_address" '{}' | jq -r '.result.address')

            # Close the wallet.
            close_wallet
        fi

        # Save to state file.
        echo "$wallet_name;$address;$MAX_ROUNDS" >> "$STATE_FILE"
    done
}

# Prompt for password if DEFAULT_PASSWORD is set to '0'.
prompt_for_password() {
    if [ "$DEFAULT_PASSWORD" = "0" ]; then
        while true; do
            read -sp "Please enter password to use for wallets (leave empty for no password): " password
            echo
            read -sp "Please confirm the wallet password: " password_confirm
            echo

            if [ "$password" = "$password_confirm" ]; then
                DEFAULT_PASSWORD="$password"
                break
            else
                echo "Passwords do not match. Please try again."
            fi
        done
    fi
}

# Perform RPC requests with optional authentication.
rpc_request() {
    local debug_mode="$1"
    local method="$2"
    local params="$3"
    local url="http://$RPC_HOST:$RPC_PORT/json_rpc"

    # Always use real RPC calls for integration tests
    if [ "$TEST_INTEGRATION" = true ]; then
        SIMULATE_WORKFLOW=false
    fi

    if [ "$SIMULATE_WORKFLOW" = true ]; then
        echo "Simulating RPC request: method=$method, params=$params"
        # Simulate a response for the specific RPC call.
        case "$method" in
            "get_balance")
                echo '{"result": {"balance": "1000000000000", "unlocked_balance": "1000000000000"}}'
                ;;
            "get_address")
                echo '{"result": {"address": "SimulatedWalletAddress"}}'
                ;;
            "sweep_all")
                echo '{"result": {"tx_hash_list": ["simulated_tx_hash"]}}'
                ;;
            "get_version")
                echo '{"result": {"version": "16.0.0"}}'
                ;;
            *)
                echo '{"result": {}}'
                ;;
        esac
        return 0
    fi

    local data
    data=$(jq -n --argjson params "$params" \
        --arg method "$method" \
        '{"jsonrpc":"2.0","id":"0","method":$method, "params":$params}')

    local curl_cmd=("curl" "-s" "-X" "POST" "--digest" "--user" "$RPC_USERNAME:$RPC_PASSWORD" "$url" "-d" "$data" "-H" "Content-Type: application/json")
    local response
    response=$("${curl_cmd[@]}")

    # Check if response is valid JSON
    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        echo "RPC Error: Invalid JSON response: $response" >&2
        return 1
    fi

    local error
    error=$(echo "$response" | jq -r '.error' 2>/dev/null)

    if [[ "$error" != "null" && "$error" != "" ]]; then
        if [ "$VERBOSE" = true ] || [ "$debug_mode" = true ]; then
            echo "RPC Error: $error" >&2
        fi
        return 1
    fi

    if [ "$VERBOSE" = true ] || [ "$debug_mode" = true ]; then
        echo "RPC Response: $response" >&2
    fi

    echo "$response"
}

# Generate a wallet name.
generate_wallet_name() {
    echo "wallet_$(date +%s)"
}

# Generate wallets and save their details to the state file.
generate_wallets() {
    local count=$1
    local rounds=$2

    for ((i = 1; i <= count; i++)); do
        local wallet_name
        wallet_name=$(generate_wallet_name)
        local password="$DEFAULT_PASSWORD"
        local address

        # Create a new wallet.
        if [ "$SIMULATE_WORKFLOW" = true ]; then
            address="SimulatedWalletAddress_$i"
            echo "Simulating wallet creation: $wallet_name with address $address"
        else
            rpc_request false "create_wallet" '{
                "filename": "'"$wallet_name"'",
                "password": "'"$password"'",
                "language": "English"
            }'

            # Open the wallet to get the address.
            rpc_request false "open_wallet" '{
                "filename": "'"$wallet_name"'",
                "password": "'"$password"'"
            }'

            # Get the wallet address.
            address=$(rpc_request false "get_address" '{}' | jq -r '.result.address')

            # Close the wallet.
            close_wallet
        fi

        # Check for duplicate entries before saving to state file.
        if ! grep -q "^$wallet_name;" "$STATE_FILE"; then
            echo "$wallet_name;$address;$rounds" >> "$STATE_FILE"
        fi
    done
}

# Handle errors and save state.
handle_error() {
    local error_message="$1"
    local context="$2"
    if [ -n "$error_message" ]; then
        echo "[ERROR] $error_message in $context" >&2
    else
        echo "[ERROR] An unknown error occurred in $context." >&2
    fi

    # Save the current state.
    save_state

    # Exit or continue based on context.
    if [ "$SELF_RESTART" = true ]; then
        echo "Relaunching the script..."
        exec "$0" "$@"
    else
        exit 1
    fi
}

# Open a wallet.
open_wallet() {
    echo "Opening wallet: $WALLET_NAME"
    if [ "$SIMULATE_WORKFLOW" = true ]; then
        echo "Simulating wallet opening."
    else
        rpc_request false "open_wallet" '{
            "filename": "'"$WALLET_NAME"'",
            "password": "'"$DEFAULT_PASSWORD"'"
        }' || handle_error "Failed to open wallet. Aborting." "open_wallet"
    fi
}

# Close the wallet.
close_wallet() {
    echo "Closing wallet."
    if [ "$SIMULATE_WORKFLOW" = true ]; then
        echo "Simulating wallet closing."
    else
        rpc_request false "close_wallet" '{}'
    fi
}

# Get the wallet address.
get_wallet_address() {
    if [ "$SIMULATE_WORKFLOW" = true ]; then
        echo "SimulatedWalletAddress"
    else
        rpc_request false "get_address" '{}' | jq -r '.result.address'
    fi
}

# Wait for unlocked balance.
wait_for_unlocked_balance() {
    local DEST_ADDRESS
    DEST_ADDRESS=$(get_wallet_address)

    if [ "$SIMULATE_WORKFLOW" = true ]; then
        echo "Simulating unlocked balance availability."
    else
        local ADDRESS_DISPLAYED=false

        while true; do
            local BALANCE_INFO
            BALANCE_INFO=$(rpc_request false "get_balance" '{}')

            local UNLOCKED_BALANCE
            UNLOCKED_BALANCE=$(echo "$BALANCE_INFO" | jq -r '.result.unlocked_balance')

            local BALANCE
            BALANCE=$(echo "$BALANCE_INFO" | jq -r '.result.balance')

            if [[ -n "$UNLOCKED_BALANCE" ]] && [[ "$UNLOCKED_BALANCE" =~ ^[0-9]+$ ]] && [ "$UNLOCKED_BALANCE" -gt 0 ]; then
                echo "Unlocked balance available: $UNLOCKED_BALANCE"
                break
            else
                if [ "$ADDRESS_DISPLAYED" = false ]; then
                    # Check if there is locked balance.  If not, then show address:
                    if [[ -n "$BALANCE" ]] && [[ "$BALANCE" =~ ^[0-9]+$ ]] && [ "$BALANCE" -eq 0 ]; then
                        echo "No balance available. Waiting for funds to arrive and unlock."
                        echo "Please send funds to the following address to continue:"
                    else
                        echo "Locked balance available: $BALANCE"
                        echo "Please wait for the balance to unlock."
                        echo "You can send additional funds to churn to:"
                    fi

                    echo "$DEST_ADDRESS"

                    if [ "$GENERATE_QR" = true ]; then
                        qrencode -o - -t ANSIUTF8 "$DEST_ADDRESS"
                    fi

                    ADDRESS_DISPLAYED=true
                fi
                sleep 60
            fi
        done
    fi
}

# Perform churning operations.
perform_churning() {
    open_wallet

    # Use the number of remaining rounds from the state file.
    local num_rounds="$ROUNDS_LEFT"
    echo "Performing $num_rounds churning rounds."

    for ((i = 1; i <= num_rounds; i++)); do
        wait_for_unlocked_balance

        # Determine if this is the last round.
        local is_last_round=false
        if [ "$i" -eq "$num_rounds" ]; then
            is_last_round=true
        fi

        local DEST_ADDRESS
        if [ "$is_last_round" = true ]; then
            # Find the next wallet address for the final round.
            DEST_ADDRESS=$(grep -A1 "^$WALLET_NAME;" "$STATE_FILE" | tail -n 1 | cut -d ';' -f2)
            echo "Last round: Sweeping funds to the next wallet: $DEST_ADDRESS"
        else
            # Send funds to self for churning.
            DEST_ADDRESS="$WALLET_ADDRESS"
            echo "Churning round $i: Sending funds to self."
        fi

        local TX_ID
        if [ "$SIMULATE_WORKFLOW" = true ]; then
            echo "Simulating transaction submission for churning round $i."
            TX_ID="simulated_tx_hash_$i"
        else
            TX_ID=$(rpc_request false "sweep_all" '{
                "address": "'"$DEST_ADDRESS"'",
                "get_tx_keys": true
            }' | jq -r '.result.tx_hash_list[]')
        fi

        if [ -z "$TX_ID" ]; then
            echo "Failed to sweep funds. Retrying in 60 seconds..."
            sleep 60
            continue
        fi

        echo "Transaction submitted: $TX_ID"

        # Update the wallet state after each round.
        update_wallet_state

        # If this was the last round, exit the loop.
        if [ "$is_last_round" = true ]; then
            break
        fi

        local DELAY=$((RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY))
        echo "Waiting for $DELAY seconds before next round."
        sleep "$DELAY"
    done
}

# Sweep to the next wallet.
sweep_to_next_wallet() {
    local next_wallet_address="$1"
    echo "Sweeping all funds to next wallet: $next_wallet_address"

    if [ "$SIMULATE_WORKFLOW" = true ]; then
        echo "Simulating sweep to next wallet: $next_wallet_address"
    else
        local TX_ID
        TX_ID=$(rpc_request false "sweep_all" '{
            "address": "'"$next_wallet_address"'",
            "get_tx_keys": true
        }' | jq -r '.result.tx_hash_list[]')

        if [ -z "$TX_ID" ]; then
            echo "Failed to sweep funds to next wallet. Retrying in 60 seconds..."
            sleep 60
        else
            echo "Sweep transaction to next wallet submitted: $TX_ID"
        fi
    fi
}

# Function to check and create state file if it doesn't exist.
initialize_state_file() {
    if [ "$SIMULATE_WORKFLOW" = true ]; then
        if [ ! -f "$STATE_FILE" ]; then
            echo "Simulated state file not found. Generating new wallets..."
            touch "$SIM_STATE_FILE"
            generate_wallets "$NUM_SESSIONS" "$MAX_ROUNDS"
        fi
    else
        if [ ! -f "$STATE_FILE" ]; then
            echo "State file not found. Generating new wallets..."
            touch "$STATE_FILE"  # Create the state file if it doesn't exist.
            generate_wallets "$NUM_SESSIONS" "$MAX_ROUNDS"
        fi
    fi
}

# Save the current state to the state file.
save_state() {
    # Create the updated content based on the current wallet state.
    local updated_file=""

    while IFS=';' read -r wallet_name address rounds_left; do
        if [ -n "$wallet_name" ] && [ "$wallet_name" = "$WALLET_NAME" ]; then
            # Only decrement if rounds_left is greater than zero
            if [ "$rounds_left" -gt 0 ]; then
                rounds_left=$((rounds_left - 1))
            fi
        fi
        # Only add valid lines to the updated file content.
        if [ -n "$wallet_name" ] && [ -n "$address" ]; then
            updated_file+="$wallet_name;$address;$rounds_left"$'\n'
        fi
    done < "$STATE_FILE"

    # Remove any empty lines before saving.
    echo "$updated_file" | sed '/^$/d' > "$STATE_FILE"
}

# Load wallet state from the state file.
load_wallet_state() {
    initialize_state_file  # Ensure state file is initialized properly.

    local found_wallet=false
    while IFS=';' read -r wallet_name address rounds_left; do
        if [[ -n "$rounds_left" && "$rounds_left" -gt 0 ]]; then
            WALLET_NAME="$wallet_name"
            WALLET_ADDRESS="$address"
            ROUNDS_LEFT="$rounds_left"
            found_wallet=true
            return
        fi
    done < "$STATE_FILE"

    # If no wallets have remaining rounds, set found_wallet to false and exit the loop
    if [ "$found_wallet" = false ]; then
        echo "No wallets with remaining rounds found."
        return 1  # Exit with a status code to indicate no wallets found
    fi
}

# Update wallet state in the state file.
update_wallet_state() {
    local updated_file=""
    local found_wallet=false

    # Check if the file exists and is readable.
    if [ -f "$STATE_FILE" ]; then
        while IFS=';' read -r wallet_name address rounds_left; do
            if [ -n "$wallet_name" ] && [ "$wallet_name" = "$WALLET_NAME" ]; then
                found_wallet=true
                # Only decrement if rounds_left is greater than zero
                if [ "$rounds_left" -gt 0 ]; then
                    rounds_left=$((rounds_left - 1))
                fi
            fi
            # Only add valid lines to the updated file content.
            if [ -n "$wallet_name" ] && [ -n "$address" ]; then
                updated_file+="$wallet_name;$address;$rounds_left"$'\n'
            fi
        done < "$STATE_FILE"

        # Save the updated state back to the file.
        echo "$updated_file" > "$STATE_FILE"
    else
        echo "[ERROR] State file not found: $STATE_FILE" >&2
    fi

    # Check if the wallet is fully churned and log a message.
    if [ "$found_wallet" = true ] && [ "$rounds_left" -eq 0 ]; then
        echo "Wallet $WALLET_NAME has completed all churning rounds."
    fi
}

# Integration tests function
integration_tests() {
    printf '%*s\n' 80 | tr ' ' '='
    echo "Running integration tests..."

    # Initialize counters for passed and failed tests.
    local passed_tests=0
    local failed_tests=0

    # Test RPC connectivity.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing RPC connectivity..."
    local version_response
    version_response=$(rpc_request false "get_version" '{}')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to connect to RPC server or authenticate. Check your configuration."
        failed_tests=$((failed_tests + 1))
    else
        # Extract and display the version information
        local version_major
        local version_minor
        version_major=$(echo "$version_response" | jq -r '.result.version' | cut -d'.' -f1)
        version_minor=$(echo "$version_response" | jq -r '.result.version' | cut -d'.' -f2)
        echo "RPC server version: $version_major.$version_minor"
        passed_tests=$((passed_tests + 1))
    fi

    # Test creating a wallet.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing wallet creation..."
    WALLET_NAME="wallet_$(date +%s)"
    local create_wallet_response
    create_wallet_response=$(rpc_request false "create_wallet" '{
        "filename": "'"$WALLET_NAME"'",
        "password": "'"$DEFAULT_PASSWORD"'",
        "language": "English"
    }')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to create wallet."
        failed_tests=$((failed_tests + 1))
    else
        echo "Wallet created successfully: $WALLET_NAME"
        passed_tests=$((passed_tests + 1))
    fi

    # Test opening a wallet.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing wallet opening..."
    local open_wallet_response
    open_wallet_response=$(rpc_request false "open_wallet" '{
        "filename": "'"$WALLET_NAME"'",
        "password": "'"$DEFAULT_PASSWORD"'"
    }')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to open wallet."
        failed_tests=$((failed_tests + 1))
    else
        echo "Wallet opened successfully: $WALLET_NAME"
        passed_tests=$((passed_tests + 1))
    fi

    # Test getting wallet address.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing getting wallet address..."
    local address_response
    address_response=$(rpc_request false "get_address" '{}')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to get wallet address."
        failed_tests=$((failed_tests + 1))
    else
        local address
        address=$(echo "$address_response" | jq -r '.result.address')
        echo "Wallet address: $address"
        passed_tests=$((passed_tests + 1))
    fi

    # Test refreshing wallet.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing wallet refresh..."
    local refresh_response
    refresh_response=$(rpc_request false "refresh" '{}')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to refresh wallet."
        failed_tests=$((failed_tests + 1))
    else
        echo "Wallet refreshed successfully."
        passed_tests=$((passed_tests + 1))
    fi

    # Test getting balance.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing getting wallet balance..."
    local balance_response
    balance_response=$(rpc_request false "get_balance" '{}')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to get wallet balance."
        failed_tests=$((failed_tests + 1))
    else
        local balance
        local unlocked_balance
        balance=$(echo "$balance_response" | jq -r '.result.balance')
        unlocked_balance=$(echo "$balance_response" | jq -r '.result.unlocked_balance')
        echo "Wallet balance: $balance atomic units"
        echo "Unlocked balance: $unlocked_balance atomic units"
        passed_tests=$((passed_tests + 1))
    fi

    # Test sweep_all transaction without broadcasting.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing sweep_all transaction (do_not_relay)..."
    local sweep_all_response
    sweep_all_response=$(rpc_request false "sweep_all" '{
        "address": "'"$address"'",
        "do_not_relay": true,
        "get_tx_keys": true
    }')

    # Check for specific errors
    if [ $? -ne 0 ]; then
        if echo "$sweep_all_response" | jq -e '.error.message == "Failed to get height"' >/dev/null; then
            echo "Sweep transaction creation passed: Expected error due to daemon height retrieval issue."
            passed_tests=$((passed_tests + 1))
        elif echo "$sweep_all_response" | jq -e '.error.message == "No unlocked balance in the specified account"' >/dev/null; then
            echo "Sweep transaction creation passed: Expected error due to no unlocked balance."
            passed_tests=$((passed_tests + 1))
        else
            echo "Failed: Unexpected error occurred during sweep transaction."
            failed_tests=$((failed_tests + 1))
        fi
    else
        local tx_hash
        tx_hash=$(echo "$sweep_all_response" | jq -r '.result.tx_hash_list[]')
        if [[ -n "$tx_hash" ]]; then
            echo "Sweep transaction created (not broadcasted), tx_hash: $tx_hash"
            passed_tests=$((passed_tests + 1))
        else
            echo "Sweep transaction creation failed: Unexpected response."
            failed_tests=$((failed_tests + 1))
        fi
    fi

    # Test closing the wallet.
    printf '%*s\n' 80 | tr ' ' '-'
    echo "Testing wallet closing..."
    local close_wallet_response
    close_wallet_response=$(rpc_request false "close_wallet" '{}')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to close wallet."
        failed_tests=$((failed_tests + 1))
    else
        echo "Wallet closed successfully."
        passed_tests=$((passed_tests + 1))
    fi

    # Display the summary of test results.
    printf '%*s\n' 80 | tr ' ' '='
    echo -e "Integration Tests Summary:\n"
    echo "Passed tests: $passed_tests"
    echo "Failed tests: $failed_tests"

    if [ $failed_tests -eq 0 ]; then
        echo -e "\nAll integration tests passed!"
    else
        echo -e "\nSome integration tests failed. Exiting without entering the main workflow."
        printf '%*s\n' 80 | tr ' ' '='
        exit 0
    fi
}

if [ "$TEST_INTEGRATION" = true ]; then
    integration_tests
fi

if [ "$INTERACTIVE_MODE" = true ]; then
    interactive_mode
fi

prompt_for_password

# Main workflow.
session_count=0
while true; do
    load_wallet_state

    # Check if load_wallet_state found any wallet with remaining rounds
    if [ $? -ne 0 ]; then
        if [ "$session_count" -ge "$NUM_SESSIONS" ]; then
            echo "Maximum number of sessions ($NUM_SESSIONS) reached or no wallets with remaining rounds.  Exiting."
            break
        fi

        session_count=$((session_count + 1))

        echo "Generating new wallets for session $session_count..."
        generate_wallets "$NUM_SESSIONS" "$MAX_ROUNDS"
        continue
    fi

    if [[ "$ROUNDS_LEFT" -gt 0 ]]; then
        perform_churning
    fi
done

echo "All sessions completed."

# After all sessions are completed, check if a final sweep is required.
if [ -n "$SWEEP_ADDRESS" ]; then
    echo "Preparing to sweep all remaining funds to final address: $final_address"

    wait_for_unlocked_balance

    echo "Sweeping remaining funds to final sweep address: $SWEEP_ADDRESS"
    sweep_to_next_wallet "$SWEEP_ADDRESS"
else
    echo "No final sweep address provided.  Exiting."
fi
