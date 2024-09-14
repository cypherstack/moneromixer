#!/bin/bash

# Monero Mixer
#
# A simple script to perform churning on Monero wallets.  See the README for required dependendies.

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

# Churning parameters.
MIN_ROUNDS=5     # [rounds] Minimum number of churning rounds per session.
MAX_ROUNDS=10    # [rounds] Maximum number of churning rounds per session.
MIN_DELAY=10     # [seconds] Minimum delay between transactions in seconds.
MAX_DELAY=30     # [seconds] Maximum delay between transactions in seconds.
NUM_SESSIONS=3   # [sessions] Number of churning sessions to perform.

# Generate a random password.
generate_random_password() {
    echo "$(openssl rand -base64 16)"
}

# Create a new wallet.
create_new_wallet() {
    if [ "$USE_SEED_FILE" = true ]; then
        if [ ! -f "$SEED_FILE" ]; then
            echo "Seed file not found!"
            exit 1
        fi
        SEED=$(head -n 1 "$SEED_FILE")
        sed -i '1d' "$SEED_FILE"
        WALLET_NAME=$(echo "$SEED" | cut -d' ' -f1)
        echo "$SEED" > "$WALLET_DIR/${WALLET_NAME}_seed.txt"
        MNEMONIC="$SEED"
        echo "Creating wallet from seed: $WALLET_NAME"
        curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"restore_deterministic_wallet",
            "params":{
                "restore_height":0,
                "filename":"'"$WALLET_NAME"'",
                "seed":"'"$MNEMONIC"'",
                "password":"'"$PASSWORD"'",
                "language":"English"
            }
        }' -H 'Content-Type: application/json' > /dev/null
        # TODO: Use a more accurate (recent) restore_height.
    else
        WALLET_NAME="wallet_$(date +%s)"
        echo "Creating new wallet: $WALLET_NAME"
        curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"create_wallet",
            "params":{
                "filename":"'"$WALLET_NAME"'",
                "password":"'"$PASSWORD"'",
                "language":"English"
            }
        }' -H 'Content-Type: application/json' > /dev/null

        # Save the seed.
        MNEMONIC=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"query_key",
            "params":{
                "key_type":"mnemonic"
            }
        }' -H 'Content-Type: application/json' | jq -r '.result.key')
        echo "$MNEMONIC" > "$WALLET_DIR/${WALLET_NAME}_seed.txt"
    fi

    if [ "$USE_RANDOM_PASSWORD" = true ]; then
        PASSWORD=$(generate_random_password)
        echo "Password: $PASSWORD" >> "$WALLET_DIR/${WALLET_NAME}_seed.txt"
    fi
}

# Open a wallet.
open_wallet() {
    echo "Opening wallet: $WALLET_NAME"
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"open_wallet",
        "params":{
            "filename":"'"$WALLET_NAME"'",
            "password":"'"$PASSWORD"'"
        }
    }' -H 'Content-Type: application/json' > /dev/null
}

# Close the wallet.
close_wallet() {
    echo "Closing wallet"
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"close_wallet"
    }' -H 'Content-Type: application/json' > /dev/null
}

# Churn.
perform_churning() {
    NUM_ROUNDS=$((RANDOM % (MAX_ROUNDS - MIN_ROUNDS + 1) + MIN_ROUNDS))
    echo "Performing $NUM_ROUNDS churning rounds"

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
            # TODO: Make this delay dynamic/psuedo-random.
            continue
        fi

        # Send to self
        echo "Churning round $i: Sending funds to self"
        DEST_ADDRESS=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"get_address"
        }' -H 'Content-Type: application/json' | jq -r '.result.address')

        TX_ID=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"transfer",
            "params":{
                "destinations":[{"amount":'"$UNLOCKED_BALANCE"',"address":"'"$DEST_ADDRESS"'"}],
                "get_tx_key": true
            }
        }' -H 'Content-Type: application/json' | jq -r '.result.tx_hash')
        # TODO: Add configuration to send less than the full unlocked balance.

        echo "Transaction submitted: $TX_ID"

        # Wait for a random delay.
        DELAY=$((RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY))
        echo "Waiting for $DELAY seconds before next round"
        sleep "$DELAY"
    done
}

# Main workflow:

mkdir -p "$WALLET_DIR"

for ((session=1; session<=NUM_SESSIONS; session++)); do
    echo "Starting session $session"

    # Create a new wallet.
    create_new_wallet
    open_wallet

    # Set daemon address.
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"set_daemon",
        "params":{
            "address":"'"$DAEMON_ADDRESS"'"
        }
    }' -H 'Content-Type: application/json' > /dev/null

    # Refresh wallet.
    curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
        "jsonrpc":"2.0",
        "id":"0",
        "method":"refresh"
    }' -H 'Content-Type: application/json' > /dev/null

    # Perform churning.
    perform_churning

    # Close wallet.
    close_wallet

    # Sweep all funds to new wallet in next session (if not the last session).
    if [ "$session" -lt "$NUM_SESSIONS" ]; then
        echo "Preparing to sweep funds to new wallet"

        # Open current wallet.
        open_wallet

        # Create next wallet.
        NEXT_WALLET_NAME="wallet_$(date +%s)_next"
        echo "Creating next wallet: $NEXT_WALLET_NAME"
        curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"create_wallet",
            "params":{
                "filename":"'"$NEXT_WALLET_NAME"'",
                "password":"'"$PASSWORD"'",
                "language":"English"
            }
        }' -H 'Content-Type: application/json' > /dev/null

        # Get address of next wallet.
        curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"open_wallet",
            "params":{
                "filename":"'"$NEXT_WALLET_NAME"'",
                "password":"'"$PASSWORD"'"
            }
        }' -H 'Content-Type: application/json' > /dev/null

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
        echo "Sweeping all funds to next wallet"
        SWEEP_TX_ID=$(curl -s -X POST http://$RPC_HOST:$RPC_PORT/json_rpc -d '{
            "jsonrpc":"2.0",
            "id":"0",
            "method":"sweep_all",
            "params":{
                "address":"'"$NEXT_ADDRESS"'",
                "get_tx_keys": true
            }
        }' -H 'Content-Type: application/json' | jq -r '.result.tx_hash_list[]')

        echo "Sweep transaction submitted: $SWEEP_TX_ID"

        # Close wallet.
        close_wallet

        # Update wallet name for next session.
        WALLET_NAME="$NEXT_WALLET_NAME"
    fi

    echo "Session $session completed"
done

echo "All sessions completed"
