# Monero Mixer
A script to perform churning on Monero wallets using monero-wallet-rpc.

# Getting started
## Install dependencies:
- Ensure you have `jq` and `curl` installed for JSON parsing:
  ```bash
  sudo apt-get install jq curl
  ```

- (Optional) Install `qrencode` in order to generate QR codes:
  ```bash
  sudo apt-get install qrencode
  ```

## Set up `monero-wallet-rpc:`
- Start `monero-wallet-rpc` with a placeholder wallet or no wallet:
  ```bash
  monero-wallet-rpc --rpc-bind-port 18082 --disable-rpc-login --daemon-address 127.0.0.1:18081
  ```
  `--disable-rpc-login` is used for simplicity in this example command.  In a 
    production environment, you should use secure RPC authentication.

## Configure the script:
Open the `moneromixer.sh` script and adjust the configuration variables at the 
top to match your environment and preferences.

- `RPC_HOST`, `RPC_PORT`, `RPC_USERNAME`, `RPC_PASSWORD`, and `DAEMON_ADDRESS` 
  should match your Monero setup.
- Adjust `MIN_ROUNDS`, `MAX_ROUNDS`, `MIN_DELAY`, `MAX_DELAY`, and 
  `NUM_SESSIONS` to control the churning behavior.
- `DEFAULT_PASSWORD` can be set to your desired default wallet password.  Set 
  to "0" to prompt for password entry.  Leave it empty ("") if no password is 
  desired.
- `GENERATE_QR` can be set to true to generate a QR code for receiving funds to
  churn.  Requires `qrencode`.
- Set `SELF_RESTART` to true if you want the script to restart itself after the
  configured number of sessions or after an error.  This is useful for long-
  term churning.

## Run the script:
- Make the script executable:
  ```bash
  chmod +x moneromixer.sh
  ```

- Run the script:
  ```bash
  ./moneromixer.sh
  ```

# Configure script to restart / loop
- If you want the script to restart itself after a certain number of sessions 
  or after an error, set `SELF_RESTART` to `true`.
- If you want the script to run indefinitely, set `NUM_SESSIONS` to `0`.
- You can also use a tool like `systemd` to manage the script as a service, as 
  in:
  ```
  [Unit]
  Description=Monero Mixer Script
  After=network.target
    
  [Service]
  Type=simple
  ExecStart=/path/to/moneromixer.sh
  Restart=always
  RestartSec=5
    
  [Install]
  WantedBy=multi-user.target
  ```

- Enable and start the service:
  ```
  sudo systemctl enable moneromixer
  sudo systemctl start moneromixer
  ```

# Workflow overview
## Sessions and rounds
- The script runs for a specified number of sessions (`NUM_SESSIONS`).
- Within each session, it performs a random number of churning rounds between 
  `MIN_ROUNDS` and `MAX_ROUNDS`.
- In each round, it sends all available unlocked funds to the wallet's own 
  address.

## Delays
- Between each transaction, the script waits for a random delay between 
  `MIN_DELAY` and `MAX_DELAY` seconds.

## Wallet management
- Each session uses a different wallet.
- Funds are swept to the next wallet at the end of each session or the sweep 
  address on the last session.

## Passwords
- Wallets can use a predefined password or no password.

# Notes
- Use this script responsibly.  Excessive churning can contribute to network 
  load.
- Ensure compliance with Monero's best practices and community guidelines.

# Workflow simulation
Workflow simulation is offered as a tool which disables RPC calls but simulates
the workflow for debugging and development purposes.  Set `SIMULATE_WORKFLOW` 
to `TRUE` to simulate the workflow.
