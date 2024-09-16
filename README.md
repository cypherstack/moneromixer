# Monero Mixer

A simple script to perform churning on Monero wallets using monero-wallet-rpc.

# Getting started
## Install Dependencies:

  - Ensure you have `jq` installed for JSON parsing:
    ```bash
    sudo apt-get install jq
    ```

Additional dependencies are required for certain optional features; you can skip these, if their
respective features are enabled but their dependencies missing, the script will prompt their 
installation.

  - Install `openssl` in order to generate random passwords:
    ```bash
    sudo apt-get install openssl
    ```

  - Install `qrencode` in order to generate QR codes:
    ```bash
    sudo apt-get install qrencode
    ```

## Set Up `monero-wallet-rpc:`

  - Start `monero-wallet-rpc` with a placeholder wallet or no wallet:
    ```bash
    monero-wallet-rpc --rpc-bind-port 18082 --disable-rpc-login --daemon-address 127.0.0.1:18081
    ```
    - Security Note: `--disable-rpc-login` is used for simplicity in this example command.  In a 
      production environment, you should use secure RPC authentication.

## Configure the Script:

Open the `moneromixer.sh` script and adjust the configuration variables at the top to match your
environment and preferences.

  - `RPC_HOST`, `RPC_PORT`, `RPC_USERNAME`, `RPC_PASSWORD`, and `DAEMON_ADDRESS` should match your 
    Monero setup.
  - Set `USE_RANDOM_PASSWORD` to true if you want random passwords generated and saved alongside the
    mnemonics.
  - `DEFAULT_PASSWORD` can be set to your desired default wallet password.  Set to "0" to prompt for
    password entry.  Leave it empty ("") if no password is desired.
  - Set `USE_SEED_FILE` to true if you want to use mnemonics from a file.  If false, new wallets 
    will be created.
  - `SAVE_SEEDS_TO_FILE` can be set to true to save seeds to a file in cleartext.  WARNING: If 
    false, the only record of these wallets will be in the wallet files created by monero-wallet-rpc. 
    If you lose those files, you will lose their funds.
  - `GENERATE_QR` can be set to true to generate a QR code for receiving funds to churn.  Requires 
    `qrencode`.
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
    - If `USE_SEED_FILE` is false, it creates new wallets.
    - If `SAVE_SEEDS_TO_FILE` is true, it saves the mnemonics to a file.
  - Between sessions (except the last one), it sweeps all funds to the next wallet.

## Passwords
  - Wallets can use a predefined password, no password, or a randomly generated password.
  - Random passwords are saved alongside the mnemonics if `USE_RANDOM_PASSWORD` is `true`.

# Notes

## Security Considerations

- This script is for testing and prototyping purposes.  In a production environment, ensure that 
your RPC endpoints are secured.
- Be cautious with wallet passwords and mnemonic seeds.  Do not expose them to insecure environments.

## Disclaimer

- Use this script responsibly. Excessive churning can contribute to network load.
- Ensure compliance with Monero's best practices and community guidelines.
