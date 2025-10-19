```
sudo ./vlan_tool.sh -i eth0 -s
```

```
Usage: $(basename "$0") [-i INTERFACE] [-f VLAN_FILE] [-r] [-s] [-n] [-h]
  -i, --interface   Parent NIC (default: eth0)
  -f, --file        Path to VLAN definition file
  -r, --reset-only  Remove all VLAN subinterfaces on INTERFACE and exit
  -s, --show        Display current VLAN subinterfaces on INTERFACE and exit
  -n, --dry-run     Print actions without applying changes
  -h, --help        Show this help

VLAN file format (one entry per line; '#' starts a comment):
  <vlan_id> <ip/cidr>
  <vlan_id> <ip> <prefixlen>

Examples:
  90 10.11.9.10/24
  120 192.168.50.2 24
```
