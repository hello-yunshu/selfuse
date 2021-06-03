#!/bin/bash

find_ip() {
	/etc/init.d/haproxy stop
	wait
	/etc/init.d/passwall stop
	wait
	cd /yunshu/shell/cloudflare

	./CloudflareST -dn 10 -tll 30 -o cf_result.txt

	wait
	sleep 3

	if [[ -f "cf_result.txt" ]]; then
		first=$(sed -n '2p' cf_result.txt | awk -F ',' '{print $1}') && echo $first >>ip-all.txt
		second=$(sed -n '3p' cf_result.txt | awk -F ',' '{print $1}') && echo $second >>ip-all.txt
		third=$(sed -n '4p' cf_result.txt | awk -F ',' '{print $1}') && echo $third >>ip-all.txt
		forth=$(sed -n '5p' cf_result.txt | awk -F ',' '{print $1}') && echo $forth >>ip-all.txt
		wait
		uci commit passwall
		wait
		sed -i "s/$(uci get passwall.573736ca855246c1a6344efbc6426cdf.address)/${first}/g" /etc/config/passwall
		sed -i "s/$(uci get passwall.f70e025e89c44701bc60e02dfccb64b3.address)/${second}/g" /etc/config/passwall
		sed -i "s/$(uci get passwall.9fbdbe9b0b204a098124aaf6a85bc53e.address)/${third}/g" /etc/config/passwall
		sed -i "s/$(uci get passwall.4a1d5fee605e479b9a3a5526338ebf90.address)/${forth}/g" /etc/config/passwall
		#uci set passwall.f70e025e89c44701bc60e02dfccb64b3.address="${second}"
		#uci set passwall.9fbdbe9b0b204a098124aaf6a85bc53e.address="${third}"
		wait
		uci commit passwall
		wait
		[[ $(/etc/init.d/haproxy status) != "running" ]] && /etc/init.d/haproxy start
		wait
		[[ $(/etc/init.d/passwall status) != "running" ]] && /etc/init.d/passwall start
		wait
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
	for ((i = 5; ${scur} > i; )); do
		sleep 60
		scur=$(curl -s 'http://192.168.2.1:1188/;csv;norefresh' -H 'Authorization: Basic eXVuc2h1OkxvdWlzb3dlbjk2MDIyMC4=' | grep "FRONTEND" | grep -v "console" | awk -F ',' '{print $5}' | awk '{sum+=$1} END {print sum}')
		if [[ ${snum} -lt 20 ]]; then
			snum=$((${snum} + 1))
		else
			exit 0
		fi
	done
}

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

	if [[ ! -f "CloudflareST" || ${version} != ${old_version} ]]; then
		rm -rf CloudflareST_linux_${tag}.tar.gz
		wget -N https://github.com/XIU2/CloudflareSpeedTest/releases/download/${version}/CloudflareST_linux_${tag}.tar.gz
		echo "${version}" >CloudflareST_version.txt
		tar -xvf CloudflareST_linux_${tag}.tar.gz
		chmod +x CloudflareST
	fi

}

check_running

sleep $((($RANDOM % 60) + 1))

check_update

find_ip

sleep 5

http_status=$(curl -I -m 10 -o /dev/null -s -w %{http_code} https://www.google.com)

until ((${http_status} == "200")); do
	find_ip
	sleep 5
done
