#!/bin/bash

# Monero Mixer
#
# A script to perform churning on Monero wallets.  See the README for required dependencies.  Can
# generate random wallets and save them for future reference or use a pre-determined series of seeds
# saved to a file.  Seeds are recorded in the same format from which they may be read, as in:
# ```
# mnemonic: <mnemonic seed words>; [password: <wallet password>;] [creation_height: <block height>]
# ```
#
# For example:
# ```
# mnemonic: abandon...; password: hunter1; creation_height: 3212321
# mnemonic: abandon...; password: hunter2; creation_height: 3232323
# ```
#
# Usage:
# - Configure the script parameters below.
# - Make the script executable if needed:
#   ```
#   chmod +x moneromixer.sh
#   ```
# - Run the script:
#   ```
#   ./moneromixer.sh
#   ```

# Configuration.
RPC_PORT=18082
RPC_HOST="127.0.0.1"
DAEMON_ADDRESS="127.0.0.1:18081"

# Path to store wallets and seeds.
WALLET_DIR="./wallets"
SEED_FILE="./seeds.txt"
PASSWORD="your_default_password"  # Set to empty if no password is desired.
USE_RANDOM_PASSWORD=false         # Set to true to use random passwords.
USE_SEED_FILE=false               # Set to true to use seeds from a file generating and saving them.
GENERATE_QR=false                 # Set to true to generate a QR code for receiving funds to churn.
                                  # (Only applies when no funds are available to churn.)

# Churning parameters
MIN_ROUNDS=5     # [rounds] Minimum number of churning rounds per session.
MAX_ROUNDS=10    # [rounds] Maximum number of churning rounds per session.
MIN_DELAY=10     # [seconds] Minimum delay between transactions.
MAX_DELAY=30     # [seconds] Maximum delay between transactions.
NUM_SESSIONS=3   # [sessions] Number of churning sessions to perform.  Set to 0 for infinite.

# Restore height offset when creation height is unknown.
RESTORE_HEIGHT_OFFSET=1000  # [blocks] Blocks to subtract from current height if unknown creation_height.

# Generate a random password.
generate_random_password() {
    echo "$(openssl rand -base64 16)"
}

# Get the current block height.
get_current_block_height() {
    HEIGHT=$(curl -s -X POST http://$DAEMON_ADDRESS/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"get_info"
    }' -H 'Content-Type: application/json' | jq -r '.result.height')
    echo "$HEIGHT"
}

# Create a new wallet.
create_new_wallet() {
    if [ "$USE_SEED_FILE" = true ]; then
        if [ ! -f "$SEED_FILE" ]; then
            echo "Seed file not found!"
            exit 1
        fi

        get_seed_info "$session"

        echo "Restoring wallet from seed: $WALLET_NAME"

        curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
            \"jsonrpc\":\"2.0\",
            \"id\":\"0\",
            \"method\":\"restore_deterministic_wallet\",
            \"params\":{
                \"restore_height\":$RESTORE_HEIGHT,
                \"filename\":\"$WALLET_NAME\",
                \"seed\":\"$MNEMONIC\",
                \"password\":\"$PASSWORD\",
                \"language\":\"English\"
            }
        }" -H 'Content-Type: application/json' > /dev/null
    else
        WALLET_NAME="wallet_$(date +%s)"
        echo "Creating new wallet: $WALLET_NAME"

        if [ "$USE_RANDOM_PASSWORD" = true ]; then
            PASSWORD=$(generate_random_password)
            echo "Generated random password: $PASSWORD"
        fi

        curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
            \"jsonrpc\":\"2.0\",
            \"id\":\"0\",
            \"method\":\"create_wallet\",
            \"params\":{
                \"filename\":\"$WALLET_NAME\",
                \"password\":\"$PASSWORD\",
                \"language\":\"English\"
            }
        }" -H 'Content-Type: application/json' > /dev/null

        # Get the mnemonic seed.
        MNEMONIC=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"query_key",
            "params":{
                "key_type":"mnemonic"
            }
        }' -H 'Content-Type: application/json' | jq -r '.result.key')

        # Get the creation height.
        CREATION_HEIGHT=$(get_current_block_height)

        # Save the seed file.
        SEED_FILE_PATH="$WALLET_DIR/${WALLET_NAME}_seed.txt"
        {
            echo "mnemonic: $MNEMONIC; password: $PASSWORD; creation_height: $CREATION_HEIGHT"
        } > "$SEED_FILE_PATH"
        echo "Seed information saved to $SEED_FILE_PATH"
    fi
}

# Open a wallet.
open_wallet() {
    echo "Opening wallet: $WALLET_NAME"
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
        \"jsonrpc\":\"2.0\",
        \"id\":\"0\",
        \"method\":\"open_wallet\",
        \"params\":{
            \"filename\":\"$WALLET_NAME\",
            \"password\":\"$PASSWORD\"
        }
    }" -H 'Content-Type: application/json' > /dev/null
}

# Close the wallet.
close_wallet() {
    echo "Closing wallet."
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"close_wallet"
    }' -H 'Content-Type: application/json' > /dev/null
}

# Wait for unlocked balance.
wait_for_unlocked_balance() {
    # Get the wallet's address.
    DEST_ADDRESS=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"get_address"
    }' -H 'Content-Type: application/json' | jq -r '.result.address')

    ADDRESS_DISPLAYED=false

    while true; do
        # Get balance and unlock time.
        BALANCE_INFO=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_balance"
        }' -H 'Content-Type: application/json')

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
                  qrencode -o - -t ANSIUTF8 "$DEST_ADDRESS" # Can use ASCII instead of ANSIUTF8.
                fi

                ADDRESS_DISPLAYED=true
            else
                echo "Still waiting for funds to arrive and unlock."
            fi
            sleep 60  # Wait before checking again.
            # TODO: Make the wait time configurable or pseudo-random.
        fi
    done
}

# Perform churning.
perform_churning() {
    NUM_ROUNDS=$((RANDOM % (MAX_ROUNDS - MIN_ROUNDS + 1) + MIN_ROUNDS))
    echo "Performing $NUM_ROUNDS churning rounds."

    for ((i=1; i<=NUM_ROUNDS; i++)); do
        # Get balance and unlock time.
        BALANCE_INFO=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_balance"
        }' -H 'Content-Type: application/json')
        UNLOCKED_BALANCE=$(echo "$BALANCE_INFO" | jq -r '.result.unlocked_balance')

        # Check if there is enough balance.
        if [ "$UNLOCKED_BALANCE" -eq 0 ]; then
            echo "No unlocked balance available. Waiting for funds to unlock."
            sleep 60
            continue
        fi

        # Send to self.
        echo "Churning round $i: Sending funds to self."
        DEST_ADDRESS=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_address"
        }' -H 'Content-Type: application/json' | jq -r '.result.address')

        TX_ID=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
            \"jsonrpc\":\"2.0\",
            \"id\":\"0\",
            \"method\":\"transfer\",
            \"params\":{
                \"destinations\":[{\"amount\":$UNLOCKED_BALANCE,\"address\":\"$DEST_ADDRESS\"}],
                \"get_tx_key\": true
            }
        }" -H 'Content-Type: application/json' | jq -r '.result.tx_hash')
        # TODO: Add configuration to send less than the full unlocked balance.

        echo "Transaction submitted: $TX_ID"

        # Wait for a random delay.
        DELAY=$((RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY))
        echo "Waiting for $DELAY seconds before next round."
        sleep "$DELAY"
    done
}

# Get seed information from the seed file (if used).
get_seed_info() {
    local index=$1
    local line
    line=$(sed -n "${index}p" "$SEED_FILE")
    if [ -z "$line" ]; then
        echo "No seed found at index $index."
        exit 1
    fi

    # Remove any leading/trailing whitespace.
    line=$(echo "$line" | xargs)

    # Check if the line contains any semicolons.
    if [[ "$line" == *";"* ]]; then
        # Parse the seed file entry.
        # Expected format:
        # "mnemonic: <mnemonic seed words>; [password: <wallet password>;] [creation_height: <block height>]"
        IFS=';' read -ra PARTS <<< "$line"
        for part in "${PARTS[@]}"; do
            key=$(echo "$part" | cut -d':' -f1 | xargs)
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
        PASSWORD="$PASSWORD"        # Use default PASSWORD variable.
        CREATION_HEIGHT=""          # Will calculate restore height below.
    fi

    if [ -z "$MNEMONIC" ]; then
        echo "Mnemonic not found in seed file entry."
        exit 1
    fi

    if [ -z "$CREATION_HEIGHT" ]; then
        # If creation_height is not provided, set restore_height to current height minus offset.
        CURRENT_HEIGHT=$(get_current_block_height)
        RESTORE_HEIGHT=$((CURRENT_HEIGHT - RESTORE_HEIGHT_OFFSET))
    else
        RESTORE_HEIGHT="$CREATION_HEIGHT"
    fi

    WALLET_NAME="wallet_$(date +%s)"
}

# Run a churning session.
run_session() {
    echo "Starting session $session."

    # Create a new wallet.
    create_new_wallet
    open_wallet

    # Set daemon address.
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
        \"jsonrpc\":\"2.0\",
        \"id\":\"0\",
        \"method\":\"set_daemon\",
        \"params\":{
            \"address\":\"$DAEMON_ADDRESS\"
        }
    }" -H 'Content-Type: application/json' > /dev/null

    # Refresh wallet.
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"refresh"
    }' -H 'Content-Type: application/json' > /dev/null

    # Wait for unlocked balance if wallet is new and has no balance.
    wait_for_unlocked_balance

    # Perform churning.
    perform_churning

    # Close wallet.
    close_wallet

    # Prepare to sweep funds to new wallet in next session (if not the last session).
    if [ "$NUM_SESSIONS" -eq 0 ] || [ "$session" -lt "$NUM_SESSIONS" ]; then
        echo "Preparing to sweep funds to new wallet."

        # Open current wallet.
        open_wallet

        if [ "$USE_SEED_FILE" = true ]; then
            NEXT_SEED_INDEX=$((SEED_INDEX + 1))
            get_seed_info "$NEXT_SEED_INDEX"

            TEMP_WALLET_NAME="temp_next_wallet"

            echo "Restoring next wallet from seed: $TEMP_WALLET_NAME"

            # Restore the next wallet using the seed
            curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
                \"jsonrpc\":\"2.0\",
                \"id\":\"0\",
                \"method\":\"restore_deterministic_wallet\",
                \"params\":{
                    \"restore_height\":$RESTORE_HEIGHT,
                    \"filename\":\"$TEMP_WALLET_NAME\",
                    \"password\":\"$PASSWORD\",
                    \"seed\":\"$MNEMONIC\",
                    \"language\":\"English\"
                }
            }" -H 'Content-Type: application/json' > /dev/null

            # Open the next wallet.
            curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
                \"jsonrpc\":\"2.0\",
                \"id\":\"0\",
                \"method\":\"open_wallet\",
                \"params\":{
                    \"filename\":\"$TEMP_WALLET_NAME\",
                    \"password\":\"$PASSWORD\"
                }
            }" -H 'Content-Type: application/json' > /dev/null

            # Get address of next wallet.
            NEXT_ADDRESS=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
                "jsonrpc":"2.0",
                "id":"0",
                "method":"get_address"
            }' -H 'Content-Type: application/json' | jq -r '.result.address')

            # Close next wallet.
            close_wallet

            # Delete the temporary wallet files.
            rm -f "$TEMP_WALLET_NAME"*
        else
            # Create next wallet as before
        fi

        # Sweep all to next wallet.
        echo "Sweeping all funds to next wallet."
        SWEEP_TX_ID=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
            \"jsonrpc\":\"2.0\",
            \"id\":\"0\",
            \"method\":\"sweep_all\",
            \"params\":{
                \"address\":\"$NEXT_ADDRESS\",
                \"get_tx_keys\": true
            }
        }" -H 'Content-Type: application/json' | jq -r '.result.tx_hash_list[]')

        echo "Sweep transaction submitted: $SWEEP_TX_ID"

        # Close wallet.
        close_wallet
    fi

    echo "Session $session completed."
}

####################################################################################################
# Main workflow:
####################################################################################################

# Check if jq is installed.
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: 'jq' is not installed."
    echo "Please install it by running:"
    echo ""
    echo "sudo apt-get install jq"
    exit 1
fi

# Check if openssl is installed (only if random passwords are used).
if [ "$USE_RANDOM_PASSWORD" = true ] && ! command -v openssl >/dev/null 2>&1; then
    echo "Error: 'openssl' is required for generating random passwords but is not installed."
    echo "Please install it by running:"
    echo ""
    echo "sudo apt-get install openssl"
    exit 1
fi

# Check if qrencode is installed (only if QR codes are used).
if [ "$GENERATE_QR" = true ] && ! command -v qrencode >/dev/null 2>&1; then
    echo "Error: 'qrencode' is required for generating QR codes but is not installed."
    echo "Please install it by running:"
    echo ""
    echo "sudo apt-get install qrencode"
    exit 1
fi

mkdir -p "$WALLET_DIR"
session=1

if [ "$NUM_SESSIONS" -eq 0 ]; then
    echo "NUM_SESSIONS is set to 0. The script will run sessions indefinitely."
    while true; do
        run_session
        session=$((session + 1))
    done
else
    while [ "$session" -le "$NUM_SESSIONS" ]; do
        run_session
        session=$((session + 1))
    done

    echo "All sessions completed."
fi
