#!/bin/bash

check_update() {
	[[ ! -d "/yunshu/shell/cloudflare" ]] && mkdir -p /yunshu/shell/cloudflare
	cd /yunshu/shell/cloudflare

	#opkg install jq

	arch=$(uname -m)
	if [[ ${arch} =~ "x86" ]]; then
		tag="amd"
		[[ ${arch} =~ "64" ]] && tag="amd64"
	elif [[ ${arch} =~ "aarch" ]]; then
		tag="arm"
		[[ ${arch} =~ "64" ]] && tag="arm64"
	else
		exit 1
	fi

	version=$(curl -s https://api.github.com/repos/XIU2/CloudflareSpeedTest/tags | jq -r .[].name | head -1)
	old_version=$(cat CloudflareST_version.txt)

	if [[ ${version} != "" ]] && [[ ! -f "CloudflareST" || ${version} != ${old_version} ]]; then
		rm -rf CloudflareST_linux_${tag}.tar.gz
		wget -N https://github.com/XIU2/CloudflareSpeedTest/releases/download/${version}/CloudflareST_linux_${tag}.tar.gz
		echo "${version}" >CloudflareST_version.txt
		tar -xvf CloudflareST_linux_${tag}.tar.gz
		chmod +x CloudflareST
		[[ -f "/usr/share/passwall/rules/direct_ip_pre.txt" ]] && (cat /usr/share/passwall/rules/direct_ip_pre.txt; echo; cat /yunshu/shell/cloudflare/ip.txt) >/usr/share/passwall/rules/direct_ip
		[[ -f "/etc/mosdns/rule/cloudflare-cidr.txt" ]] && (cat /yunshu/shell/cloudflare/ip.txt; echo; cat /yunshu/shell/cloudflare/ipv6.txt) >/etc/mosdns/rule/cloudflare-cidr.txt
	fi

}

find_ip() {
	#/etc/init.d/haproxy stop
	#
	#/etc/init.d/passwall stop
	#

	#sleep 1

	cd /yunshu/shell/cloudflare

	./CloudflareST -dn 10 -tll 30 -tl 230 -tlr 0.01 -url https://speed.cloudflare.com/__down?bytes=200000000 -o cf_result.txt

	
	sleep 1

	if [[ -f "cf_result.txt" ]]; then
		first=$(sed -n '2p' cf_result.txt | awk -F ',' '{print $1}') && echo $first >>ip-all.txt
		second=$(sed -n '3p' cf_result.txt | awk -F ',' '{print $1}') && echo $second >>ip-all.txt
		third=$(sed -n '4p' cf_result.txt | awk -F ',' '{print $1}') && echo $third >>ip-all.txt
		forth=$(sed -n '5p' cf_result.txt | awk -F ',' '{print $1}') && echo $forth >>ip-all.txt
		
		if [[ ${forth} == "" ]]; then
			exit 1
		fi
		
		#uci commit passwall
		#
		sed -i "s/$(uci get passwall.573736ca855246c1a6344efbc6426cdf.address)/${first}/g" /etc/config/passwall
		sed -i "s/$(uci get passwall.f70e025e89c44701bc60e02dfccb64b3.address)/${second}/g" /etc/config/passwall
		sed -i "s/$(uci get passwall.9fbdbe9b0b204a098124aaf6a85bc53e.address)/${third}/g" /etc/config/passwall
		sed -i "s/$(uci get passwall.4a1d5fee605e479b9a3a5526338ebf90.address)/${forth}/g" /etc/config/passwall
		#uci set passwall.f70e025e89c44701bc60e02dfccb64b3.address="${second}"
		#uci set passwall.9fbdbe9b0b204a098124aaf6a85bc53e.address="${third}"
		
		uci commit passwall
		
		uci del mosdns.config.cloudflare_ip
		uci add_list mosdns.config.cloudflare_ip="${first}"
		uci add_list mosdns.config.cloudflare_ip="${second}"
		uci add_list mosdns.config.cloudflare_ip="${third}"
		uci add_list mosdns.config.cloudflare_ip="${forth}"
		
		uci commit mosdns
		
		#[[ $(/etc/init.d/haproxy status) != "running" ]] && /etc/init.d/haproxy start
		
		#[[ $(/etc/init.d/passwall status) != "running" ]] && /etc/init.d/passwall start
		/etc/init.d/passwall restart
		sleep 1
		/etc/init.d/haproxy restart

		if ! pgrep -x "haproxy" > /dev/null
		then
			/etc/init.d/haproxy restart
		fi

		/etc/init.d/mosdns restart

		if [[ -f "ip-all.txt" ]]; then
			sort -t "." -k4 -n -r ip-all.txt >ip-all-serialize.txt
			uniq -c ip-all.txt ip-mediate.txt
			sort -r ip-mediate.txt >ip-statistics.txt
			rm -rf ip-mediate.txt
		fi
	fi

}

check_running() {
	scur=1
	snum=0
	for ((i = 3; ${scur} > i; )); do
		sleep 10
		scur=$(curl -s 'http://192.168.2.1:1188/;csv;norefresh' -H 'Authorization: Basic eXVuc2h1OkxvdWlzb3dlbjk2MDIyMC4=' | grep "FRONTEND" | grep -v "console" | awk -F ',' '{print $5}' | awk '{sum+=$1} END {print sum}')
		if [[ ${snum} -lt 30 ]]; then
			snum=$((${snum} + 1))
		else
			exit 0
		fi
	done
}

#[[ -f "/yunshu/shell/cloudflare/cf.running" ]] && exit 0

#touch /yunshu/shell/cloudflare/cf.running

sleep $((($RANDOM % 30) + 1))

check_update

check_running

find_ip

#rm -rf /yunshu/shell/cloudflare/cf.running
