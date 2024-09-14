#!/bin/bash

# Monero Mixer
#
# A script to perform churning on Monero wallets. See the README for required dependencies.

# Configuration.
RPC_PORT=18082
RPC_HOST="127.0.0.1"
DAEMON_ADDRESS="127.0.0.1:18081"

# Path to store wallets and seeds.
WALLET_DIR="./wallets"
SEED_FILE="./seeds.txt"
PASSWORD="your_default_password"  # Set to empty if no password is desired.
USE_RANDOM_PASSWORD=false         # Set to true to use random passwords.
USE_SEED_FILE=false               # Set to true to use seeds from a file.

# Churning parameters
MIN_ROUNDS=5     # [rounds] Minimum number of churning rounds per session.
MAX_ROUNDS=10    # [rounds] Maximum number of churning rounds per session.
MIN_DELAY=10     # [seconds] Minimum delay between transactions.
MAX_DELAY=30     # [seconds] Maximum delay between transactions.
NUM_SESSIONS=3   # [sessions] Number of churning sessions to perform.

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

        # Read the first wallet entry from the seed file.
        IFS='' read -r line < "$SEED_FILE"
        sed -i '1d' "$SEED_FILE"

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

        # Save the wallet information.
        SEED_FILE_PATH="$WALLET_DIR/${WALLET_NAME}_seed.txt"
        {
            echo "# Wallet Seed File Format:"
            echo "# mnemonic: <mnemonic seed words>"
            echo "# password: <wallet password>"
            echo "# creation_height: <block height>"
            echo ""
            echo "mnemonic: $MNEMONIC"
            echo "password: $PASSWORD"
            echo "creation_height: $RESTORE_HEIGHT"
        } > "$SEED_FILE_PATH"
        echo "Seed information saved to $SEED_FILE_PATH"
    else
        WALLET_NAME="wallet_$(date +%s)"
        echo "Creating new wallet: $WALLET_NAME"
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

        if [ "$USE_RANDOM_PASSWORD" = true ]; then
            PASSWORD=$(generate_random_password)
        fi

        # Save the seed file.
        SEED_FILE_PATH="$WALLET_DIR/${WALLET_NAME}_seed.txt"
        {
            echo "# Wallet Seed File Format:"
            echo "# mnemonic: <mnemonic seed words>"
            echo "# password: <wallet password>"
            echo "# creation_height: <block height>"
            echo ""
            echo "mnemonic: $MNEMONIC"
            echo "password: $PASSWORD"
            echo "creation_height: $CREATION_HEIGHT"
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
    while true; do
        # Get balance and unlock time.
        BALANCE_INFO=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_balance"
        }' -H 'Content-Type: application/json')

        UNLOCKED_BALANCE=$(echo "$BALANCE_INFO" | jq -r '.result.unlocked_balance')

        if [ "$UNLOCKED_BALANCE" -gt 0 ]; then
            echo "Unlocked balance available: $UNLOCKED_BALANCE"
            break
        else
            echo "No unlocked balance available. Waiting for funds to arrive and unlock."
            sleep 60  # Wait before checking again.
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

# Main workflow:

mkdir -p "$WALLET_DIR"

for ((session=1; session<=NUM_SESSIONS; session++)); do
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

    # Sweep all funds to new wallet in next session (if not the last session).
    if [ "$session" -lt "$NUM_SESSIONS" ]; then
        echo "Preparing to sweep funds to new wallet."

        # Open current wallet.
        open_wallet

        # Create next wallet.
        NEXT_WALLET_NAME="wallet_$(date +%s)_next"
        echo "Creating next wallet: $NEXT_WALLET_NAME"
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

        # Get address of next wallet.
        curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d "{
            \"jsonrpc\":\"2.0\",
            \"id\":\"0\",
            \"method\":\"open_wallet\",
            \"params\":{
                \"filename\":\"$NEXT_WALLET_NAME\",
                \"password\":\"$PASSWORD\"
            }
        }" -H 'Content-Type: application/json' > /dev/null

        NEXT_ADDRESS=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_address"
        }' -H 'Content-Type: application/json' | jq -r '.result.address')

        # Close next wallet.
        close_wallet

        # Switch back to current wallet.
        open_wallet

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

        # Update wallet name for next session.
        WALLET_NAME="$NEXT_WALLET_NAME"
    fi

    echo "Session $session completed."
done

echo "All sessions completed."
