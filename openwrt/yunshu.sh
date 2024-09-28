#!/bin/bash
# sleep 8
# cp -rf /yunshu/usr/bin/* /usr/bin/
sleep 3
uci set dhcp.lan.ra=hybrid
uci set dhcp.lan.dhcpv6=hybrid
uci set dhcp.lan.ndp=hybrid
uci set dhcp.lan.ra_management=1
uci commit dhcp
# uci delete firewall.@defaults[0].flow_offloading
# uci set firewall.@defaults[0].natflow='1'
# uci commit firewall
wait
sleep 1
service network restart
#service firewall restart