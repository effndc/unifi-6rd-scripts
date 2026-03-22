# unifi-6rd-scripts

Scripts to configure IPv6 6RD on Unifi Cloud Gateways.

## Overview

This project provides scripts to set up IPv6 6RD (IPv6 Rapid Deployment) tunneling on a **Unifi Cloud Gateway**. The scripts were developed and tested on **firmware v5.0.16**.

The scripts were developed for **CenturyLink** as the ISP, but can be easily adapted for other 6RD providers by updating the configuration variables in `centurylink-6rd-setup.sh`.

## Usage

1. Clone or download the repository to your Unifi Cloud Gateway.
2. Open `centurylink-6rd-setup.sh` and update the variables at the top of the file to match your ISP's 6RD settings (relay address, prefix length, IPv4 address, etc.).
3. Run the script to configure 6RD tunneling.

## Adapting for Other Providers

If you are using a provider other than CenturyLink, update the relevant variables in `centurylink-6rd-setup.sh`:

- **6RD relay address** – Your ISP's 6RD border relay IPv4 address
- **6RD prefix** – The IPv6 prefix assigned by your ISP for 6RD
- **6RD prefix length** – The prefix length provided by your ISP
- **IPv4 mask length** – The number of IPv4 bits to include in the 6RD prefix

## Requirements

- Unifi Cloud Gateway running firmware **v5.0.16** or compatible

## License

See [LICENSE](LICENSE) for details.
