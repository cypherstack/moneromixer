# Monero Mixer

A simple script to perform churning on Monero wallets.

# Getting started
## Install Dependencies:

  - Ensure you have `jq` installed for JSON parsing:
    ```bash
    sudo apt-get install jq
    ```
  - Make sure `openssl` is installed for generating random passwords:
    ```bash
    sudo apt-get install openssl
    ```

## Set Up `monero-wallet-rpc:`

  - Start `monero-wallet-rpc` with a placeholder wallet or no wallet:
    ```bash
    monero-wallet-rpc --rpc-bind-port 18082 --disable-rpc-login --daemon-address 127.0.0.1:18081
    ```
    - Security Note: `--disable-rpc-login` is used for simplicity in this script.  In a production 
      environment, you should use secure RPC authentication.

## Configure the Script:

  - Open the `moneromixer.sh` script and adjust the configuration variables at the top to match your
    environment and preferences.
  - `RPC_PORT`, `RPC_HOST`, and `DAEMON_ADDRESS` should match your Monero setup.
  - `WALLET_DIR` is the directory where wallets and seeds will be stored.
  - `SEED_FILE` is the path to a text file containing mnemonics (one per line) if you're using 
     predefined seeds.
  - `PASSWORD` can be set to your desired default password. Leave it empty ("") if no password is 
     desired. 
  - Set `USE_RANDOM_PASSWORD` to true if you want random passwords generated and saved alongside the
    mnemonics. 
  - Set `USE_SEED_FILE` to true if you want to use mnemonics from a file. 
  - Adjust `MIN_ROUNDS`, `MAX_ROUNDS`, `MIN_DELAY`, `MAX_DELAY`, and `NUM_SESSIONS` to control the 
    churning behavior.

## Run the Script:

  - Make the script executable:
    ```bash
    chmod +x moneromixer.sh
    ```

  - Run the script:
    ```bash
    ./moneromixer.sh
    ```

## Monitor the Process:

  - The script will output the progress of each session, including transaction hashes. 
  - Wallets and seeds will be saved in the specified `WALLET_DIR`.

# Workflow overview
## Sessions and Rounds

  - The script runs for a specified number of sessions (`NUM_SESSIONS`).
  - Within each session, it performs a random number of churning rounds between `MIN_ROUNDS` and 
    `MAX_ROUNDS`.
  - In each round, it sends all available unlocked funds to the wallet's own address.

## Delays
  - Between each transaction, the script waits for a random delay between `MIN_DELAY` and 
    `MAX_DELAY` seconds.

## Wallet Management
  - At the beginning of each session, a new wallet is created.
    - If `USE_SEED_FILE` is true, it restores wallets from a list of mnemonics.
    - If `USE_SEED_FILE` is false, it creates new wallets and saves their mnemonics.
  - Between sessions (except the last one), it sweeps all funds to the next wallet.

## Passwords
  - Wallets can use a predefined password, no password, or a randomly generated password.
  - Random passwords are saved alongside the mnemonics if `USE_RANDOM_PASSWORD` is `true`.

# Notes

## Security Considerations

- This script is for testing and prototyping purposes. In a production environment, ensure that your 
RPC endpoints are secured.
- Be cautious with wallet passwords and mnemonic seeds. Do not expose them to insecure environments.

## Disclaimer

- Use this script responsibly. Excessive churning can contribute to network load.
- Ensure compliance with Monero's best practices and community guidelines.
