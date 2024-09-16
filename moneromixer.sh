#!/bin/bash

# Monero Mixer
#
# A churning script.  Requires `jq` and optionally `openssl` and/or `qrencode`.  Uses the Monero
# wallet RPC to create, restore, and churn wallets.  The script can be configured to generate and
# record random wallets and save them for future reference or use a pre-determined series of seeds
# saved to a file.  Seeds are recorded in the same format from which they may be read as in:
# mnemonic: <mnemonic seed words>; [password: <wallet password>;] [creation_height: <block height>]
#
# For example:
# mnemonic: abandon...; password: hunter1; creation_height: 3212321
# mnemonic: abandon...; password: hunter2; creation_height: 3232323
#
# Usage:
# - Configure the script parameters below.
# - Make the script executable if needed:
#   chmod +x moneromixer.sh
# - Run the script:
#   ./moneromixer.sh

# RPC configuration.
RPC_HOST="127.0.0.1"
RPC_PORT=18082
DAEMON_ADDRESS="127.0.0.1:18081"
RPC_USERNAME="username"
RPC_PASSWORD="password"

# General configuration.
WALLET_DIR="./wallets"
SEED_FILE="./seeds.txt"
DEFAULT_PASSWORD="0"      # Default wallet password.  Set to "0" to prompt for password input.
USE_RANDOM_PASSWORD=false # Set to true to use random passwords.  Requires openssl.
USE_SEED_FILE=false       # Set to true to read seeds from a file.  See the top of this script for
                          # seed file format.  When false, generates new wallets.
SAVE_SEEDS_TO_FILE=false  # Set to true to save seeds to a file in cleartext.  WARNING: If false,
                          # the only record of these wallets will be in the wallet files created by
                          # monero-wallet-rpc.  If you lose those files, you will lose their funds.
GENERATE_QR=false         # Set to true to generate a QR code for receiving funds to churn.
                          # Requires qrencode.
DEBUG_MODE=false          # Set to true to enable debug mode.  Simulates the workflow without RPC.
INTEGRATION_TEST=true     # Set to true to run integration tests.

# Churning parameters.
MIN_ROUNDS=5     # [rounds] Minimum number of churning rounds per session.
MAX_ROUNDS=50    # [rounds] Maximum number of churning rounds per session.
MIN_DELAY=1      # [seconds] Minimum delay between transactions.
MAX_DELAY=3600   # [seconds] Maximum delay between transactions.
NUM_SESSIONS=3   # [sessions] Number of churning sessions to perform.  Set to 0 for infinite.

# Restore height offset when creation height is unknown.
RESTORE_HEIGHT_OFFSET=1000  # [blocks] Blocks to subtract from current height if unknown creation_height.

# Generate a random password.
generate_random_password() {
    echo "$(openssl rand -base64 16)"
}

# Determine if RPC authentication is needed.
if [ -n "$RPC_USERNAME" ] && [ -n "$RPC_PASSWORD" ]; then
    CURL_AUTH=("--user" "$RPC_USERNAME:$RPC_PASSWORD")
else
    CURL_AUTH=()
fi

# Function to perform RPC requests with optional authentication.
rpc_request() {
    local debug_mode="$1"
    local method="$2"
    local params="$3"
    local url="http://$RPC_HOST:$RPC_PORT/json_rpc"

    local data
    data=$(jq -n --argjson params "$params" \
        --arg method "$method" \
        '{"jsonrpc":"2.0","id":"0","method":$method, "params":$params}')

    # Construct the curl command.
    local curl_cmd=("curl" "-s" "-X" "POST" "--digest")
    if [ -n "$RPC_USERNAME" ] && [ -n "$RPC_PASSWORD" ]; then
        curl_cmd+=("--user" "$RPC_USERNAME:$RPC_PASSWORD")
    fi
    curl_cmd+=("$url" "-d" "$data" "-H" "Content-Type: application/json")

    # Print the curl command and the request data if in debug mode.
    if [ "$debug_mode" = true ] || [ "$DEBUG_MODE" = true ]; then
        echo "Executing RPC request:"
        printf '%q ' "${curl_cmd[@]}"
        echo
        echo "Request Data: $data"
    fi

    # Execute the curl command and capture the response.
    local response
    response=$("${curl_cmd[@]}")

    # Print the full response for debugging.
    if [ "$debug_mode" = true ] || [ "$DEBUG_MODE" = true ]; then
        echo "Full RPC Response:"
        echo "$response"
    fi

    # Check for errors in the response.
    local error
    error=$(echo "$response" | jq -r '.error' 2>/dev/null)

    if [[ "$error" != "null" && "$error" != "" ]]; then
        echo "RPC Error: $error"
        return 1
    fi

    # Return the response only if it is not empty.
    if [[ "$response" == "{}" ]] || [[ -z "$response" ]]; then
        if [ "$debug_mode" = true ] || [ "$DEBUG_MODE" = true ]; then
            echo "Empty response received for method: $method"
        fi
        return 1
    else
        echo "$response"
    fi
}

# Get the current block height.
get_current_block_height() {
    local HEIGHT
    if [ "$DEBUG_MODE" = true ]; then
        HEIGHT=1000000  # Simulated block height in debug mode.
    else
        HEIGHT=$(curl -s -X POST "${CURL_AUTH[@]}" http://$DAEMON_ADDRESS/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_info"
        }' -H 'Content-Type: application/json' | jq -r '.result.height')
    fi
    echo "$HEIGHT"
}

# Save the seed file.
save_seed_file() {
    if [ "$SAVE_SEEDS_TO_FILE" = true ]; then
        {
            echo "mnemonic: $MNEMONIC; password: $PASSWORD; creation_height: $CREATION_HEIGHT"
        } >> "$SEED_FILE"
        echo "Seed information appended to $SEED_FILE"
    else
        echo "Seed saving is disabled. Seed information will not be saved to a file."
    fi
}

# Create or restore a wallet.
create_or_restore_wallet() {
    WALLET_NAME="wallet_${session}"

    if [ "$USE_SEED_FILE" = true ]; then
        get_seed_info "$SEED_INDEX"
        echo "Restoring wallet from seed: $WALLET_NAME"

        if [ "$DEBUG_MODE" = true ]; then
            echo "(Debug mode) Simulating wallet restoration."
            MNEMONIC="simulated mnemonic seed words"
            CREATION_HEIGHT=$(get_current_block_height)
        else
            echo 1234123
            if ! rpc_request false "restore_deterministic_wallet" '{
                "restore_height": '"$RESTORE_HEIGHT"',
                "filename": "'"$WALLET_NAME"'",
                "seed": "'"$MNEMONIC"'",
                "password": "'"$PASSWORD"'",
                "language": "English"
            }'; then
                echo "Failed to restore wallet. Aborting."
                exit 1
            fi
        fi
    else
        echo "Creating new wallet: $WALLET_NAME"

        if [ "$USE_RANDOM_PASSWORD" = true ]; then
            PASSWORD=$(generate_random_password)
            echo "Generated random password: $PASSWORD"
        else
            PASSWORD="$DEFAULT_PASSWORD"
        fi

        if [ "$DEBUG_MODE" = true ]; then
            echo "(Debug mode) Simulating wallet creation."
            MNEMONIC="simulated mnemonic seed words"
            CREATION_HEIGHT=$(get_current_block_height)
            save_seed_file
        else
            if ! rpc_request false "create_wallet" '{
                "filename": "'"$WALLET_NAME"'",
                "password": "'"$PASSWORD"'",
                "language": "English"
            }'; then
                echo "Failed to create wallet. Aborting."
                exit 1
            fi

            # Continue only if the response is valid
            open_wallet

            # Get the mnemonic seed.
            MNEMONIC=$(rpc_request false "query_key" '{"key_type": "mnemonic"}' | jq -r '.result.key')

            # Get the creation height.
            CREATION_HEIGHT=$(get_current_block_height)

            # Save the seed file.
            save_seed_file
        fi
    fi
}


# Open a wallet.
open_wallet() {
    echo "Opening wallet: $WALLET_NAME"
    if [ "$DEBUG_MODE" = true ]; then
        echo "(Debug mode) Simulating wallet opening."
    else
        if ! rpc_request false "open_wallet" '{
            "filename": "'"$WALLET_NAME"'",
            "password": "'"$PASSWORD"'"
        }'; then
            echo "Failed to open wallet. Aborting."
            exit 1
        fi
    fi
}

# Close the wallet.
close_wallet() {
    echo "Closing wallet."
    if [ "$DEBUG_MODE" = true ]; then
        echo "(Debug mode) Simulating wallet closing."
    else
        rpc_request false "close_wallet" '{}' #> /dev/null
    fi
}

# Get wallet address.
get_wallet_address() {
    local ADDRESS
    if [ "$DEBUG_MODE" = true ]; then
        ADDRESS="SimulatedWalletAddress_${session}"
    else
        ADDRESS=$(rpc_request false "get_address" '{}' | jq -r '.result.address')
    fi
    echo "$ADDRESS"
}

# Wait for unlocked balance.
wait_for_unlocked_balance() {
    local DEST_ADDRESS
    DEST_ADDRESS=$(get_wallet_address)

    if [ "$DEBUG_MODE" = true ]; then
        echo "(Debug mode) Assuming unlocked balance is available."
    else
        local ADDRESS_DISPLAYED=false

        while true; do
            # Get balance and unlock time.
            local BALANCE_INFO
            BALANCE_INFO=$(rpc_request false "get_balance" '{}')

            local UNLOCKED_BALANCE
            UNLOCKED_BALANCE=$(echo "$BALANCE_INFO" | jq -r '.result.unlocked_balance')

            if [[ -n "$UNLOCKED_BALANCE" ]] && [[ "$UNLOCKED_BALANCE" =~ ^[0-9]+$ ]] && [ "$UNLOCKED_BALANCE" -gt 0 ]; then
                echo "Unlocked balance available: $UNLOCKED_BALANCE"
                break
            else
                if [ "$ADDRESS_DISPLAYED" = false ]; then
                    echo "No unlocked balance available. Waiting for funds to arrive and unlock."
                    echo "Please send funds to the following address to continue:"
                    echo "$DEST_ADDRESS"

                    if [ "$GENERATE_QR" = true ]; then
                        # Display QR code.
                        qrencode -o - -t ANSIUTF8 "$DEST_ADDRESS"
                    fi

                    ADDRESS_DISPLAYED=true
                else
                    echo "Still waiting for funds to arrive and unlock."
                fi
                sleep 60  # Wait before checking again.
                # TODO: Make the wait time configurable or pseudo-random.
            fi
        done
    fi
}

# Perform churning.
perform_churning() {
    local NUM_ROUNDS=$((RANDOM % (MAX_ROUNDS - MIN_ROUNDS + 1) + MIN_ROUNDS))
    echo "Performing $NUM_ROUNDS churning rounds."

    for ((i=1; i<=NUM_ROUNDS; i++)); do
        # Get balance and unlock time.
        if [ "$DEBUG_MODE" = true ]; then
            UNLOCKED_BALANCE=1000000000000  # Simulated unlocked balance in atomic units (1 XMR = 1e12 atomic units)
        else
            local BALANCE_INFO
            BALANCE_INFO=$(rpc_request false "get_balance" '{}')
            UNLOCKED_BALANCE=$(echo "$BALANCE_INFO" | jq -r '.result.unlocked_balance')
        fi

        # Check if there is enough balance.
        if [ "$UNLOCKED_BALANCE" -eq 0 ]; then
            echo "No unlocked balance available. Waiting for funds to unlock."
            sleep 60
            # TODO: Make the wait time configurable or pseudo-random.
            continue
        fi

        # Send to self.
        echo "Churning round $i: Sending funds to self."
        local DEST_ADDRESS
        DEST_ADDRESS=$(get_wallet_address)

        if [ "$DEBUG_MODE" = true ]; then
            TX_ID="SimulatedTxHash_${i}"
            echo "(Debug mode) Simulating transfer transaction."
        else
            TX_ID=$(rpc_request false "transfer" '{
                "destinations": [{"amount": '"$UNLOCKED_BALANCE"', "address": "'"$DEST_ADDRESS"'"}],
                "get_tx_key": true
            }' | jq -r '.result.tx_hash')
            # TODO: Add configuration to send less than the full unlocked balance.
        fi

        echo "Transaction submitted: $TX_ID"

        # Wait for a random delay.
        local DELAY=$((RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY))
        echo "Waiting for $DELAY seconds before next round."
        sleep "$DELAY"
    done
}

# Get seed information from the seed file.
get_seed_info() {
    local index=$1
    local line
    line=$(sed -n "${index}p" "$SEED_FILE")
    if [ -z "$line" ]; then
        if [ "$NUM_SESSIONS" -eq 0 ]; then
            # Loop back to the beginning of the seed file.
            echo "Reached end of seed file. Looping back to the beginning."
            SEED_INDEX=1
            line=$(sed -n "${SEED_INDEX}p" "$SEED_FILE")
            if [ -z "$line" ]; then
                echo "Seed file is empty."
                exit 1
            fi
        else
            echo "No seed found at index $index."
            exit 1
        fi
    fi

    # Reset PASSWORD and CREATION_HEIGHT before parsing.
    PASSWORD="$DEFAULT_PASSWORD"
    CREATION_HEIGHT=""

    # Remove any leading/trailing whitespace.
    line=$(echo "$line" | xargs)

    # Check if the line contains any semicolons.
    if [[ "$line" == *";"* ]]; then
        # Parse the seed file entry.
        IFS=';' read -ra PARTS <<< "$line"
        for part in "${PARTS[@]}"; do
            local key
            key=$(echo "$part" | cut -d':' -f1 | xargs)
            local value
            value=$(echo "$part" | cut -d':' -f2- | xargs)
            case "$key" in
                "mnemonic")
                    MNEMONIC="$value"
                    ;;
                "password")
                    PASSWORD="$value"
                    ;;
                "creation_height")
                    CREATION_HEIGHT="$value"
                    ;;
                *)
                    ;;
            esac
        done
    else
        # If no semicolons, treat the entire line as the mnemonic.
        MNEMONIC="$line"
        # PASSWORD remains as DEFAULT_PASSWORD
        # CREATION_HEIGHT remains empty
    fi

    if [ -z "$MNEMONIC" ]; then
        echo "Mnemonic not found in seed file entry."
        exit 1
    fi

    if [ -z "$CREATION_HEIGHT" ]; then
        # If creation_height is not provided, set restore_height to current height minus offset.
        local CURRENT_HEIGHT
        CURRENT_HEIGHT=$(get_current_block_height)
        RESTORE_HEIGHT=$((CURRENT_HEIGHT - RESTORE_HEIGHT_OFFSET))
    else
        RESTORE_HEIGHT="$CREATION_HEIGHT"
    fi

    WALLET_NAME="wallet_${session}"
}

# Run a churning session.
run_session() {
    echo "Starting session $session."

    # Create or restore a wallet.
    create_or_restore_wallet
    open_wallet

    # Set daemon address.
    if [ "$DEBUG_MODE" = true ]; then
        echo "(Debug mode) Simulating set_daemon."
    else
        rpc_request false "set_daemon" '{
            "address": "'"$DAEMON_ADDRESS"'"
        }' #> /dev/null
    fi

    # Refresh wallet.
    if [ "$DEBUG_MODE" = true ]; then
        echo "(Debug mode) Simulating wallet refresh."
    else
        rpc_request false "refresh" '{}' #> /dev/null
    fi

    # Wait for unlocked balance if wallet is new and has no balance.
    wait_for_unlocked_balance

    # Perform churning.
    perform_churning

    # Close wallet.
    close_wallet

    # Prepare to sweep funds to new wallet in next session (if applicable).
    if [ "$NUM_SESSIONS" -eq 0 ] || [ "$session" -lt "$NUM_SESSIONS" ]; then
        echo "Preparing to sweep funds to new wallet."

        # Open current wallet.
        open_wallet

        if [ "$USE_SEED_FILE" = true ]; then
            # Get next seed index.
            NEXT_SEED_INDEX=$((SEED_INDEX + 1))

            # Handle looping back to the beginning if end of seed file is reached.
            local total_seeds
            total_seeds=$(wc -l < "$SEED_FILE")
            if [ "$NEXT_SEED_INDEX" -gt "$total_seeds" ]; then
                if [ "$NUM_SESSIONS" -eq 0 ]; then
                    NEXT_SEED_INDEX=1  # Loop back to the beginning.
                else
                    echo "No more seeds available in the seed file."
                    exit 1
                fi
            fi

            get_seed_info "$NEXT_SEED_INDEX"

            local TEMP_WALLET_NAME="wallet_${session}_next"

            echo "Restoring next wallet from seed: $TEMP_WALLET_NAME"

            if [ "$DEBUG_MODE" = true ]; then
                echo "(Debug mode) Simulating restoration of next wallet."
                NEXT_ADDRESS="SimulatedNextWalletAddress_$((session + 1))"
            else
                # Restore the next wallet using the seed.
                rpc_request false "restore_deterministic_wallet" '{
                    "restore_height": '"$RESTORE_HEIGHT"',
                    "filename": "'"$TEMP_WALLET_NAME"'",
                    "password": "'"$PASSWORD"'",
                    "seed": "'"$MNEMONIC"'",
                    "language": "English"
                }' #> /dev/null

                # Open the next wallet.
                rpc_request false "open_wallet" '{
                    "filename": "'"$TEMP_WALLET_NAME"'",
                    "password": "'"$PASSWORD"'"
                }' #> /dev/null

                # Get address of next wallet.
                NEXT_ADDRESS=$(get_wallet_address)

                # Close next wallet.
                close_wallet

                # Delete the temporary wallet files.
                rm -f "$TEMP_WALLET_NAME"*
            fi
        else
            # Create next wallet.
            local NEXT_WALLET_NAME="wallet_$((session + 1))"
            echo "Creating next wallet: $NEXT_WALLET_NAME"

            if [ "$USE_RANDOM_PASSWORD" = true ]; then
                PASSWORD=$(generate_random_password)
                echo "Generated random password: $PASSWORD"
            else
                PASSWORD="$DEFAULT_PASSWORD"
            fi

            if [ "$DEBUG_MODE" = true ]; then
                echo "(Debug mode) Simulating creation of next wallet."
                NEXT_ADDRESS="SimulatedNextWalletAddress_$((session + 1))"
            else
                rpc_request false "create_wallet" '{
                    "filename": "'"$NEXT_WALLET_NAME"'",
                    "password": "'"$PASSWORD"'",
                    "language": "English"
                }' #> /dev/null

                # Open the next wallet.
                rpc_request false "open_wallet" '{
                    "filename": "'"$NEXT_WALLET_NAME"'",
                    "password": "'"$PASSWORD"'"
                }' #> /dev/null

                # Get address of next wallet.
                NEXT_ADDRESS=$(get_wallet_address)

                # Close next wallet.
                close_wallet

                # Save the seed of the next wallet to the SEED_FILE if enabled.
                if [ "$SAVE_SEEDS_TO_FILE" = true ]; then
                    if [ "$DEBUG_MODE" = true ]; then
                        MNEMONIC="simulated mnemonic seed words for next wallet"
                        CREATION_HEIGHT=$(get_current_block_height)
                        save_seed_file
                    else
                        # Open the next wallet to query the seed.
                        open_wallet

                        # Get the mnemonic seed of the next wallet.
                        MNEMONIC=$(rpc_request false "query_key" '{"key_type": "mnemonic"}' | jq -r '.result.key')
                        CREATION_HEIGHT=$(get_current_block_height)
                        save_seed_file

                        # Close the next wallet.
                        close_wallet
                    fi
                fi
            fi
        fi

        # Sweep all to next wallet.
        echo "Sweeping all funds to next wallet."
        if [ "$DEBUG_MODE" = true ]; then
            SWEEP_TX_ID="SimulatedSweepTxHash"
            echo "(Debug mode) Simulating sweep_all transaction."
        else
            SWEEP_TX_ID=$(rpc_request false "sweep_all" '{
                "address": "'"$NEXT_ADDRESS"'",
                "get_tx_keys": true
            }' | jq -r '.result.tx_hash_list[]')
        fi

        echo "Sweep transaction submitted: $SWEEP_TX_ID"

        # Close wallet.
        close_wallet

        # Update wallet name and seed index for next session.
        WALLET_NAME="wallet_session_$((session + 1))"
    fi

    echo "Session $session completed."
}

# Integration tests.
#
# Run by setting INTEGRATION_TEST to true and executing the script.
integration_tests() {
    echo -e "Running integration tests...\n"

    # Initialize counters for passed and failed tests.
    local passed_tests=0
    local failed_tests=0

    # Test RPC connectivity.
    echo -e "\nTesting RPC connectivity..."
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
    echo -e "\nTesting wallet creation..."
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
    echo -e "\nTesting wallet opening..."
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
    echo -e "\nTesting getting wallet address..."
    local address_response
    address_response=$(rpc_request false "get_address" '{}')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to get wallet address."
        failed_tests=$((failed_tests + 1))
    else
        # Extract and display the wallet address.
        local address
        address=$(echo "$address_response" | jq -r '.result.address')
        echo "Wallet address: $address"
        passed_tests=$((passed_tests + 1))
    fi

    # Test refreshing wallet.
    echo -e "\nTesting wallet refresh..."
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
    echo -e "\nTesting getting wallet balance..."
    local balance_response
    balance_response=$(rpc_request false "get_balance" '{}')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to get wallet balance."
        failed_tests=$((failed_tests + 1))
    else
        # Extract and display the wallet balance.
        local balance
        local unlocked_balance
        balance=$(echo "$balance_response" | jq -r '.result.balance')
        unlocked_balance=$(echo "$balance_response" | jq -r '.result.unlocked_balance')
        echo "Wallet balance: $balance atomic units"
        echo "Unlocked balance: $unlocked_balance atomic units"
        passed_tests=$((passed_tests + 1))
    fi

    # Test sweep_all transaction without broadcasting.
    echo -e "\nTesting sweep_all transaction (do_not_relay)..."
    local sweep_all_response
    sweep_all_response=$(rpc_request true "sweep_all" '{
        "address": "'"$address"'",
        "do_not_relay": true,
        "get_tx_keys": true
    }')
    if [ $? -ne 0 ]; then
        echo "Failed: Unable to create sweep_all transaction."
        failed_tests=$((failed_tests + 1))
    else
        # Check for an empty response, which is expected for a zero balance.
        if [[ -z "$sweep_all_response" || "$sweep_all_response" == "{}" ]]; then
            echo "Sweep transaction creation passed: No balance to sweep."
            passed_tests=$((passed_tests + 1))
        else
            # Extract and display the transaction details.
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
    fi

    # Test closing the wallet.
    echo -e "\nTesting wallet closing..."
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
    echo -e "\n\nIntegration Tests Summary:"
    echo "Passed tests: $passed_tests"
    echo "Failed tests: $failed_tests"

    if [ $failed_tests -eq 0 ]; then
        echo -e "\nAll integration tests passed!"
    else
        echo -e "\nSome integration tests failed."
    fi
}

####################################################################################################
# Main workflow:
####################################################################################################

# Run integration tests if enabled.
if [ "$INTEGRATION_TEST" = true ]; then
    integration_tests
fi

# Dependency checks.
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is not installed."
    echo "Please install it by running:"
    echo ""
    echo "sudo apt-get install jq"
    exit 1
fi

if [ "$USE_RANDOM_PASSWORD" = true ] && ! command -v openssl >/dev/null 2>&1; then
    echo "Error: 'openssl' is required for generating random passwords but is not installed."
    echo "Please install it by running:"
    echo ""
    echo "sudo apt-get install openssl"
    exit 1
fi

if [ "$GENERATE_QR" = true ] && ! command -v qrencode >/dev/null 2>&1; then
    echo "Error: 'qrencode' is required for generating QR codes but is not installed."
    echo "Please install it by running:"
    echo ""
    echo "sudo apt-get install qrencode"
    exit 1
fi

if [ "$DEBUG_MODE" = true ]; then
    echo "Debug mode is enabled. No RPC calls will be made."
else
    mkdir -p "$WALLET_DIR"
fi

session=1
SEED_INDEX=1

# Prompt for password if DEFAULT_PASSWORD is set to '0'.
if [ "$DEFAULT_PASSWORD" = "0" ]; then
    read -sp "Please enter the wallet password (leave empty for no password): " DEFAULT_PASSWORD
    echo
fi

if [ "$NUM_SESSIONS" -eq 0 ]; then
    echo "NUM_SESSIONS is set to 0. The script will run sessions indefinitely."
    while true; do
        run_session
        session=$((session + 1))
        SEED_INDEX=$((SEED_INDEX + 1))
    done
else
    while [ "$session" -le "$NUM_SESSIONS" ]; do
        run_session
        session=$((session + 1))
        SEED_INDEX=$((SEED_INDEX + 1))
    done

    echo "All sessions completed."
fi
