#!/bin/sh
# exegress node agent.
#
# Reads /etc/exegress/state.json (maintained by the controller) and enforces the
# datapath for this node ($NODE_NAME, from the downward API):
#   * non-active nodes: route each destination CIDR via the active gateway's
#     private IP, on the private interface.
#   * the active gateway node: alias the EIP on the public interface, enable
#     forwarding + loose rp_filter, and dest-scoped SNAT to the EIP.
# Idempotent; re-applies on a timer to survive DHCP/netplan churn and failover.
set -u

STATE=/etc/exegress/state.json
INTERVAL="${EXEGRESS_INTERVAL:-15}"

apk add --no-cache iproute2 iptables jq >/dev/null 2>&1 || true

apply_once() {
  [ -f "$STATE" ] || return 0
  count=$(jq '.gateways | length' "$STATE" 2>/dev/null || echo 0)
  i=0
  while [ "$i" -lt "$count" ]; do
    g=$(jq -c ".gateways[$i]" "$STATE")
    i=$((i + 1))
    eip=$(echo "$g" | jq -r .eip)
    active=$(echo "$g" | jq -r .activeNode)
    gwip=$(echo "$g" | jq -r .gatewayPrivateIP)
    pub=$(echo "$g" | jq -r .publicIface)
    priv=$(echo "$g" | jq -r .privateIface)

    for d in $(echo "$g" | jq -r '.destinations[]'); do
      if [ "$NODE_NAME" = "$active" ]; then
        # Active gateway: do not redirect, own the EIP + SNAT.
        ip route del "$d" 2>/dev/null || true
        ip addr add "$eip/32" dev "$pub" 2>/dev/null || true
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true
        iptables -t nat -C POSTROUTING -d "$d" -o "$pub" -j SNAT --to-source "$eip" 2>/dev/null \
          || iptables -t nat -I POSTROUTING 1 -d "$d" -o "$pub" -j SNAT --to-source "$eip"
      else
        # Other nodes: redirect destination traffic to the gateway; ensure no
        # stale gateway config remains (e.g. after a failover away from here).
        ip route replace "$d" via "$gwip" dev "$priv"
        iptables -t nat -D POSTROUTING -d "$d" -o "$pub" -j SNAT --to-source "$eip" 2>/dev/null || true
        ip addr del "$eip/32" dev "$pub" 2>/dev/null || true
      fi
    done
  done
}

echo "exegress-agent starting on node=$NODE_NAME interval=${INTERVAL}s"
while true; do
  apply_once
  sleep "$INTERVAL"
done
