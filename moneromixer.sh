#!/bin/bash

# Monero Mixer
#
# A script to perform churning on Monero wallets.  See the README for required dependencies.  Uses
# the Monero wallet RPC to create, restore, and churn wallets.  The script can be configured to
# generate and record random wallets and save them for future reference or use a pre-determined
# series of seeds saved to a file.  Seeds are recorded in the same format from which they may be
# read, as in:
#
# mnemonic: <mnemonic seed words>; [password: <wallet password>;] [creation_height: <block height>]
#
# For example:
# mnemonic: abandon...; password: hunter1; creation_height: 3212321
# mnemonic: abandon...; creation_height: 3232323
#
# In the above example, the second seed has no password and so will use the DEFAULT_PASSWORD
# configured below (which is set to "0" by default to prompt for password entry).
#
# Usage:
# - Configure the script parameters below.
# - Make the script executable if needed:
#   chmod +x moneromixer.sh
# - Run the script:
#   ./moneromixer.sh

# Configuration.
RPC_PORT=18082
RPC_HOST="127.0.0.1"
DAEMON_ADDRESS="127.0.0.1:18081"

# Path to store wallets and seeds.
WALLET_DIR="./wallets"
SEED_FILE="./seeds.txt"
DEFAULT_PASSWORD="0"      # Set to "0" to prompt for password entry.  An empty string = no password.
USE_RANDOM_PASSWORD=false # Set to true to use random passwords.  Passwords are saved with seeds.
USE_SEED_FILE=false       # Set to true to read seeds from a file.  If false, seeds are generated
                          # randomly.  Random seeds are logged into the SEED_FILE.
GENERATE_QR=false         # Set to true to generate a QR code for receiving funds to churn.

# Churning parameters.
MIN_ROUNDS=5     # [rounds] Minimum number of churning rounds per session.
MAX_ROUNDS=50    # [rounds] Maximum number of churning rounds per session.
MIN_DELAY=300    # [seconds] Minimum delay between transactions.
MAX_DELAY=2400   # [seconds] Maximum delay between transactions.
NUM_SESSIONS=0   # [sessions] Number of churning sessions to perform. Set to 0 for infinite.

# Restore height offset when creation height is unknown.
RESTORE_HEIGHT_OFFSET=1000  # [blocks] Blocks to subtract from current height if unknown
                            # creation_height.

# Generate a random password.
generate_random_password() {
    echo "$(openssl rand -base64 16)"
}

# Get the current block height.
get_current_block_height() {
    local HEIGHT
    HEIGHT=$(curl -s -X POST http://$DAEMON_ADDRESS/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"get_info"
    }' -H 'Content-Type: application/json' | jq -r '.result.height')
    echo "$HEIGHT"
}

# Save the seed file.
save_seed_file() {
    local SEED_FILE_PATH="$WALLET_DIR/${WALLET_NAME}_seed.txt"
    {
        echo "mnemonic: $MNEMONIC; password: $PASSWORD; creation_height: $CREATION_HEIGHT"
    } > "$SEED_FILE_PATH"
    echo "Seed information saved to $SEED_FILE_PATH"
}

# Create or restore a wallet.
create_or_restore_wallet() {
    WALLET_NAME="wallet_${session}"

    if [ "$USE_SEED_FILE" = true ]; then
        get_seed_info "$SEED_INDEX"

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
        WALLET_NAME="wallet_${session}"
        echo "Creating new wallet: $WALLET_NAME"

        if [ "$USE_RANDOM_PASSWORD" = true ]; then
            PASSWORD=$(generate_random_password)
            echo "Generated random password: $PASSWORD"
        else
            PASSWORD="$DEFAULT_PASSWORD"
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
        save_seed_file
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

# Get wallet address.
get_wallet_address() {
    local ADDRESS
    ADDRESS=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"get_address"
    }' -H 'Content-Type: application/json' | jq -r '.result.address')
    echo "$ADDRESS"
}

# Wait for unlocked balance.
wait_for_unlocked_balance() {
    local DEST_ADDRESS
    DEST_ADDRESS=$(get_wallet_address)

    local ADDRESS_DISPLAYED=false

    while true; do
        # Get balance and unlock time.
        local BALANCE_INFO
        BALANCE_INFO=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_balance"
        }' -H 'Content-Type: application/json')

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
}

# Perform churning.
perform_churning() {
    local NUM_ROUNDS=$((RANDOM % (MAX_ROUNDS - MIN_ROUNDS + 1) + MIN_ROUNDS))
    echo "Performing $NUM_ROUNDS churning rounds."

    for ((i=1; i<=NUM_ROUNDS; i++)); do
        # Get balance and unlock time.
        local BALANCE_INFO
        BALANCE_INFO=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_balance"
        }' -H 'Content-Type: application/json')
        local UNLOCKED_BALANCE
        UNLOCKED_BALANCE=$(echo "$BALANCE_INFO" | jq -r '.result.unlocked_balance')

        # Check if there is enough balance.
        if [ "$UNLOCKED_BALANCE" -eq 0 ]; then
            echo "No unlocked balance available. Waiting for funds to unlock."
            sleep 60
            continue
        fi

        # Send to self.
        echo "Churning round $i: Sending funds to self."
        local DEST_ADDRESS
        DEST_ADDRESS=$(get_wallet_address)

        local TX_ID
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
        # Expected format:
        # "mnemonic: <mnemonic seed words>; [password: <wallet password>;] [creation_height: <block height>]"
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

            local TEMP_WALLET_NAME="wallet_${session}"

            echo "Restoring next wallet from seed: $TEMP_WALLET_NAME"

            # Restore the next wallet using the seed.
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
            NEXT_ADDRESS=$(get_wallet_address)

            # Close next wallet.
            close_wallet

            # Delete the temporary wallet files.
            rm -f "$TEMP_WALLET_NAME"*
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

            curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
                \"jsonrpc\":\"2.0\",
                \"id\":\"0\",
                \"method\":\"create_wallet\",
                \"params\":{
                    \"filename\":\"$NEXT_WALLET_NAME\",
                    \"password\":\"$PASSWORD\",
                    \"language\":\"English\"
                }
            }" -H 'Content-Type: application/json' > /dev/null

            # Open the next wallet.
            curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
                \"jsonrpc\":\"2.0\",
                \"id\":\"0\",
                \"method\":\"open_wallet\",
                \"params\":{
                    \"filename\":\"$NEXT_WALLET_NAME\",
                    \"password\":\"$PASSWORD\"
                }
            }" -H 'Content-Type: application/json' > /dev/null

            # Get address of next wallet.
            NEXT_ADDRESS=$(get_wallet_address)

            # Close next wallet.
            close_wallet
        fi

        # Sweep all to next wallet.
        echo "Sweeping all funds to next wallet."
        local SWEEP_TX_ID
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

        # Update wallet name and seed index for next session.
        WALLET_NAME="wallet_session_$((session + 1))"
    fi

    echo "Session $session completed."
}

####################################################################################################
# Main workflow:
####################################################################################################

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

mkdir -p "$WALLET_DIR"
session=1
SEED_INDEX=1

# Prompt for password if DEFAULT_PASSWORD is set to '0'.
if [ "$DEFAULT_PASSWORD" = "0" ]; then
    read -sp "Please enter the wallet password to use (leave empty for none): " DEFAULT_PASSWORD
    echo
fi

if [ "$NUM_SESSIONS" -eq 0 ]; then
    echo "NUM_SESSIONS is set to 0.  The script will run sessions indefinitely."
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
