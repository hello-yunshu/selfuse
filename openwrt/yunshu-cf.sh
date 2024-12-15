#!/bin/bash

LOG_FILE="/yunshu/shell/cloudflare/script.log"
MAX_LOG_SIZE=500000  # 最大日志文件大小（字节）

log() {
    if [[ -f "$LOG_FILE" ]]; then
        log_size=$(stat -c%s "$LOG_FILE")
        if (( log_size >= MAX_LOG_SIZE )); then
            timestamp=$(date +%Y%m%d%H%M%S)
            mv "$LOG_FILE" "${LOG_FILE}.${timestamp}.gz"
            gzip "${LOG_FILE}.${timestamp}"
        fi
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

check_update() {
    [[ ! -d "/yunshu/shell/cloudflare" ]] && mkdir -p /yunshu/shell/cloudflare
	[[ ! -f "${LOG_FILE}" ]] && touch "$LOG_FILE"
	log "Starting check_update function"
    cd /yunshu/shell/cloudflare || { log "Failed to change directory to /yunshu/shell/cloudflare"; exit 1; }

    arch=$(uname -m)
    if [[ ${arch} =~ "x86" ]]; then
        tag="amd"
        [[ ${arch} =~ "64" ]] && tag="amd64"
    elif [[ ${arch} =~ "aarch" ]]; then
        tag="arm"
        [[ ${arch} =~ "64" ]] && tag="arm64"
    else
        log "Unsupported architecture: $arch"
        exit 1
    fi

    version=$(curl -s https://api.github.com/repos/XIU2/CloudflareSpeedTest/tags | jq -r .[].name | head -1)
    old_version=$(cat CloudflareST_version.txt 2>/dev/null)

    if [[ ${version} != "" ]] && [[ ! -f "CloudflareST" || ${version} != ${old_version} ]]; then
        log "New version detected: $version"
        rm -rf CloudflareST_linux_${tag}.tar.gz
        wget -N https://github.com/XIU2/CloudflareSpeedTest/releases/download/${version}/CloudflareST_linux_${tag}.tar.gz || { log "Failed to download CloudflareST_linux_${tag}.tar.gz"; exit 1; }
        echo "${version}" >CloudflareST_version.txt
        tar -xvf CloudflareST_linux_${tag}.tar.gz || { log "Failed to extract CloudflareST_linux_${tag}.tar.gz"; exit 1; }
        chmod +x CloudflareST
        [[ -f "/usr/share/passwall/rules/direct_ip_pre.txt" ]] && (cat /usr/share/passwall/rules/direct_ip_pre.txt; echo; cat /yunshu/shell/cloudflare/ip.txt) >/usr/share/passwall/rules/direct_ip
        [[ -f "/etc/mosdns/rule/cloudflare-cidr.txt" ]] && (cat /yunshu/shell/cloudflare/ip.txt; echo; cat /yunshu/shell/cloudflare/ipv6.txt) >/etc/mosdns/rule/cloudflare-cidr.txt
    else
        log "No update needed or already up-to-date"
    fi
}

find_ip() {
    log "Starting find_ip function"
    cd /yunshu/shell/cloudflare || { log "Failed to change directory to /yunshu/shell/cloudflare"; exit 1; }

    ./CloudflareST -dn 10 -tll 30 -tl 230 -tlr 0.01 -url https://speed.cloudflare.com/__down?bytes=200000000 -o cf_result.txt || { log "Failed to run CloudflareST"; exit 1; }

    sleep 1

    if [[ -f "cf_result.txt" ]]; then
        first=$(sed -n '2p' cf_result.txt | awk -F ',' '{print $1}')
        second=$(sed -n '3p' cf_result.txt | awk -F ',' '{print $1}')
        third=$(sed -n '4p' cf_result.txt | awk -F ',' '{print $1}')
        forth=$(sed -n '5p' cf_result.txt | awk -F ',' '{print $1}')

        if [[ ${forth} == "" ]]; then
            log "Not enough IPs found in cf_result.txt"
            exit 1
        fi

        echo "$first" >>ip-all.txt
        echo "$second" >>ip-all.txt
        echo "$third" >>ip-all.txt
        echo "$forth" >>ip-all.txt

        sed -i "s/$(uci get passwall.573736ca855246c1a6344efbc6426cdf.address)/${first}/g" /etc/config/passwall
        sed -i "s/$(uci get passwall.f70e025e89c44701bc60e02dfccb64b3.address)/${second}/g" /etc/config/passwall
        sed -i "s/$(uci get passwall.9fbdbe9b0b204a098124aaf6a85bc53e.address)/${third}/g" /etc/config/passwall
        sed -i "s/$(uci get passwall.4a1d5fee605e479b9a3a5526338ebf90.address)/${forth}/g" /etc/config/passwall
        uci commit passwall

        # uci del mosdns.config.cloudflare_ip
        # uci add_list mosdns.config.cloudflare_ip="${first}"
        # uci add_list mosdns.config.cloudflare_ip="${second}"
        # uci add_list mosdns.config.cloudflare_ip="${third}"
        # uci add_list mosdns.config.cloudflare_ip="${forth}"
        # uci commit mosdns

        /etc/init.d/passwall restart
        sleep 1
        /etc/init.d/haproxy restart

        if ! pgrep -x "haproxy" > /dev/null; then
            log "HAProxy not running, restarting..."
            /etc/init.d/haproxy restart
        fi

        # /etc/init.d/mosdns restart

        if [[ -f "ip-all.txt" ]]; then
            sort -t "." -k4 -n -r ip-all.txt >ip-all-serialize.txt
            uniq -c ip-all.txt > ip-mediate.txt
            sort -r ip-mediate.txt >ip-statistics.txt
            rm -rf ip-mediate.txt
        fi
    else
        log "cf_result.txt not found"
        exit 1
    fi
}

check_running() {
    log "Starting check_running function"
    scur=1
    snum=0
    while (( scur > 3 )); do
        sleep 10
        scur=$(curl -s 'http://192.168.2.1:1188/;csv;norefresh' -H 'Authorization: Basic eXVuc2h1OkxvdWlzb3dlbjk2MDIyMC4=' | grep "FRONTEND" | grep -v "console" | awk -F ',' '{print $5}' | awk '{sum+=$1} END {print sum}')
        if [[ ${snum} -lt 30 ]]; then
            snum=$((snum + 1))
        else
            log "Check running condition met after 30 attempts"
            break
        fi
    done
}

sleep $(( ($RANDOM % 30) + 1 ))

check_update
check_running
find_ip