#!/bin/bash
set -euo pipefail

# Defaults (can also be overridden via -i / -f or env)
INTERFACE="${INTERFACE:-eth0}"
VLAN_FILE="${VLAN_FILE:-}"
RESET_ONLY=0
SHOW_ONLY=0
DRY_RUN=0

usage() {
  cat <<EOF
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
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (e.g., sudo $0 …)"; }
run() { if ((DRY_RUN)); then echo "+ $*"; else "$@"; fi; }

load_8021q() { modprobe 8021q 2>/dev/null || true; }

# List VLAN subinterfaces that belong to the chosen parent (e.g., eth0.90)
list_vlan_devs() {
  ip -o -d link show type vlan \
  | awk -v iface="$INTERFACE" -F': ' '{
      name=$2; sub(/:.*/,"",name); split(name,a,"@");
      if (a[1] ~ "^"iface"\\.") print a[1];
    }'
}

reset_vlans() {
  local dev
  while read -r dev; do
    [[ -z "${dev:-}" ]] && continue
    run ip link set dev "$dev" down
    run ip link delete dev "$dev"
    echo "Removed $dev"
  done < <(list_vlan_devs)
}

show_vlans() {
  local dev vid state ipv4 ipv6 found=0
  while read -r dev; do
    [[ -z "${dev:-}" ]] && continue
    found=1
    vid="${dev#${INTERFACE}.}"
    if ! [[ "$vid" =~ ^[0-9]+$ ]]; then
      vid="$(ip -d -o link show dev "$dev" | sed -n 's/.* vlan id \([0-9]\+\).*/\1/p')"
    fi
    state="$(ip -o link show dev "$dev" | awk '{for(i=1;i<=NF;i++) if($i=="state"){print $(i+1); exit}}')"

    mapfile -t _v4 < <(ip -o -4 addr show dev "$dev" | awk '{print $4}')
    mapfile -t _v6 < <(ip -o -6 addr show dev "$dev" | awk '{print $4}')
    if ((${#_v4[@]})); then ipv4="$(IFS=,; echo "${_v4[*]}")"; else ipv4="-"; fi
    if ((${#_v6[@]})); then ipv6="$(IFS=,; echo "${_v6[*]}")"; else ipv6="-"; fi

    printf "%-16s vid=%-5s state=%-5s IPv4=%s IPv6=%s\n" "$dev" "${vid:-?}" "${state:-?}" "$ipv4" "$ipv6"
  done < <(list_vlan_devs)

  ((found)) || echo "No VLAN subinterfaces on $INTERFACE"
}

apply_config() {
  [[ -n "${VLAN_FILE:-}" ]] || die "VLAN file required (-f)"
  [[ -r "$VLAN_FILE" ]] || die "Cannot read $VLAN_FILE"

  load_8021q
  run ip link set dev "$INTERFACE" up

  # Ensure only definitions from the file remain on this NIC
  reset_vlans

  # Create subinterfaces and assign IPs
  declare -A created=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                           # strip trailing comment
    [[ -z "${line//[[:space:]]/}" ]] && continue # skip blank

    # Word-split the cleaned line
    set -- $line
    vlan_id="${1:-}"; second="${2:-}"; third="${3:-}"

    [[ "$vlan_id" =~ ^[0-9]+$ ]] || die "Invalid VLAN id: $vlan_id"
    (( vlan_id >= 1 && vlan_id <= 4094 )) || die "VLAN id out of range: $vlan_id"

    # Accept "IP/CIDR" or "IP PREFIXLEN"
    if [[ "$second" == */* ]]; then
      ip_cidr="$second"
    else
      [[ -n "$third" ]] || die "Missing prefix length for VLAN $vlan_id"
      [[ "$third" =~ ^[0-9]+$ ]] || die "Invalid prefix length: $third"
      (( third >= 0 && third <= 32 )) || die "Prefix length out of range: $third"
      ip_cidr="$second/$third"
    fi

    subif="${INTERFACE}.${vlan_id}"
    if [[ -z "${created[$subif]+x}" ]]; then
      run ip link add link "$INTERFACE" name "$subif" type vlan id "$vlan_id"
      run ip link set dev "$subif" up
      created[$subif]=1
      echo "Created $subif (VLAN $vlan_id)"
    fi

    run ip addr add "$ip_cidr" dev "$subif"
    echo "  + Address $ip_cidr on $subif"
  done < "$VLAN_FILE"

  echo "Done."
}

# --- main ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interface) INTERFACE="$2"; shift 2 ;;
    -f|--file)      VLAN_FILE="$2"; shift 2 ;;
    -r|--reset-only) RESET_ONLY=1; shift ;;
    -s|--show)      SHOW_ONLY=1; shift ;;
    -n|--dry-run)   DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --) shift; break ;;
    *)  die "Unknown option: $1" ;;
  esac
done

if (( RESET_ONLY && SHOW_ONLY )); then
  die "Options -r/--reset-only and -s/--show are mutually exclusive"
fi

if (( SHOW_ONLY )); then
  show_vlans
  exit 0
fi

need_root

if (( RESET_ONLY )); then
  reset_vlans
  exit 0
fi

apply_config
