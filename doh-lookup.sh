#!/bin/sh
# doh-lookup - retrieve IPv4/IPv6 addresses via dig from a given domain list
# and write the adjusted output to separate lists (IPv4/IPv6 addresses plus domains)
# Copyright (c) 2019-2023 Dirk Brenken (dev@brenken.org)
# Copyright (c) 2024 Als@admin.ru.net
#
# This is free software, licensed under the GNU General Public License v3.
#
# 2024-09-18: Added DoH server scraping from AdGuard's DNS providers list

# disable (s)hellcheck in release
# shellcheck disable=all

# prepare environment
#
export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
input1="./doh-domains_overall.txt"
input2="input2.txt"
input3="input3.txt"
doh_servers_url="https://raw.githubusercontent.com/AdguardTeam/KnowledgeBaseDNS/master/docs/general/dns-providers.md"
upstream="8.8.8.8"
check_domains="google.com heise.de openwrt.org"
cache_domains="doh.dns.apple.com doh.dns.apple.com.v.aaplimg.com mask-api.icloud.com mask-h2.icloud.com mask.icloud.com dns.nextdns.io"
wc_tool="$(command -v wc)"
dig_tool="$(command -v dig)"
awk_tool="$(command -v awk)"
curl_tool="$(command -v curl)"
: >"./${input2}"
: >"./${input3}"
: >"./ipv4.tmp"
: >"./ipv6.tmp"
: >"./ipv4_cache.tmp"
: >"./ipv6_cache.tmp"
: >"./domains.tmp"
: >"./domains_abandoned.tmp"
: >"./doh_servers.tmp"

# sanity pre-checks
#
if [ ! -x "${wc_tool}" ] || [ ! -x "${dig_tool}" ] || [ ! -x "${awk_tool}" ] || [ ! -x "${curl_tool}" ] || [ ! -s "${input1}" ] || [ -z "${upstream}" ]; then
	printf "%s\n" "ERR: general pre-check failed"
	exit 1
fi

for domain in ${check_domains}; do
	out="$("${dig_tool}" "${domain}" A "${domain}" AAAA +noall +answer +time=5 +tries=1 2>/dev/null)"
	if [ -z "${out}" ]; then
		printf "%s\n" "ERR: domain pre-check failed"
		exit 1
	else
		ips="$(printf "%s" "${out}" | "${awk_tool}" '/^.*[[:space:]]+IN[[:space:]]+A{1,4}[[:space:]]+/{printf "%s ",$NF}')"
		if [ -z "${ips}" ]; then
			printf "%s\n" "ERR: ip pre-check failed"
			exit 1
		fi
	fi
done

# Scrape DoH servers from AdGuard's DNS providers list
"${curl_tool}" -s "${doh_servers_url}" | "${awk_tool}" -F'|' '/DNS-over-HTTPS/ && /https:\/\// {
    gsub(/`/, "", $3)
    split($3, a, "/")
    print a[3]
}' >"./doh_servers.tmp"

printf "%s\n" "::: Scraped DoH servers: $("${wc_tool}" -l <"./doh_servers.tmp")"

# pre-fill cache domains
#
for domain in ${cache_domains}; do
	"${awk_tool}" -v d="${domain}" '$0~d{print $0}' "./doh-ipv4.txt" >>"./ipv4_cache.tmp"
	"${awk_tool}" -v d="${domain}" '$0~d{print $0}' "./doh-ipv6.txt" >>"./ipv6_cache.tmp"
done

# Combine DoH servers with existing domains and remove duplicates
cat "./doh_servers.tmp" "${input1}" | sort -u >"./combined_domains.tmp"

# domain processing (first run)
#
cnt="0"
doh_start1="$(date "+%s")"
doh_cnt="$("${wc_tool}" -l <"./combined_domains.tmp")"
printf "%s\n" "::: Start DOH-processing, overall unique domains: ${doh_cnt}"
while IFS= read -r domain; do
	(
		domain_ok="false"
		out="$("${dig_tool}" "${domain}" A "${domain}" AAAA +noall +answer +time=5 +tries=1 2>/dev/null)"
		if [ -n "${out}" ]; then
			ips="$(printf "%s" "${out}" | "${awk_tool}" '/^.*[[:space:]]+IN[[:space:]]+A{1,4}[[:space:]]+/{printf "%s ",$NF}')"
			if [ -n "${ips}" ]; then
				for ip in ${ips}; do
					if [ "${ip%%.*}" = "127" ] || [ "${ip%%.*}" = "0" ] || [ -z "${ip%%::*}" ]; then
						continue
					else
						if ipcalc-ng -cs "${ip}"; then
							domain_ok="true"
							if [ "${ip##*:}" = "${ip}" ]; then
								printf "%-20s%s\n" "${ip}" "# ${domain}" >>"./ipv4.tmp"
							else
								printf "%-40s%s\n" "${ip}" "# ${domain}" >>"./ipv6.tmp"
							fi
						fi
					fi
				done
			fi
		fi
		if [ "${domain_ok}" = "false" ]; then
			printf "%s\n" "$domain" >>"./${input2}"
		else
			printf "%s\n" "${domain}" >>./domains.tmp
		fi
	) &
	hold1="$((cnt % 512))"
	hold2="$((cnt % 2048))"
	[ "${hold1}" = "0" ] && sleep 3
	[ "${hold2}" = "0" ] && wait
	cnt="$((cnt + 1))"
done <"./combined_domains.tmp"
wait
error_cnt="$("${wc_tool}" -l <"./${input2}")"
doh_end="$(date "+%s")"
doh_duration="$(((doh_end - doh_start1) / 60))m $(((doh_end - doh_start1) % 60))s"
printf "%s\n" "::: First run, duration: ${doh_duration}, processed domains: ${cnt}, error domains: ${error_cnt}"

# domain processing (second run)
#
cnt="0"
doh_start2="$(date "+%s")"
while IFS= read -r domain; do
	(
		domain_ok="false"
		out="$("${dig_tool}" "@${upstream}" "${domain}" A "${domain}" AAAA +noall +answer +time=5 +tries=1 2>/dev/null)"
		if [ -n "${out}" ]; then
			ips="$(printf "%s" "${out}" | "${awk_tool}" '/^.*[[:space:]]+IN[[:space:]]+A{1,4}[[:space:]]+/{printf "%s ",$NF}')"
			if [ -n "${ips}" ]; then
				for ip in ${ips}; do
					if [ "${ip%%.*}" = "0" ] || [ -z "${ip%%::*}" ]; then
						continue
					else
						if ipcalc-ng -cs "${ip}"; then
							domain_ok="true"
							if [ "${ip##*:}" = "${ip}" ]; then
								printf "%-20s%s\n" "${ip}" "# ${domain}" >>"./ipv4.tmp"
							else
								printf "%-40s%s\n" "${ip}" "# ${domain}" >>"./ipv6.tmp"
							fi
						fi
					fi
				done
			else
				printf "%s\n" "$domain" >>"./${input3}"
			fi
		fi
		if [ "${domain_ok}" = "false" ]; then
			printf "%s\n" "${domain}" >>./domains_abandoned.tmp
		else
			printf "%s\n" "${domain}" >>./domains.tmp
		fi
	) &
	hold1="$((cnt % 512))"
	hold2="$((cnt % 2048))"
	[ "${hold1}" = "0" ] && sleep 3
	[ "${hold2}" = "0" ] && wait
	cnt="$((cnt + 1))"
done <"${input2}"
wait
error_cnt="$("${wc_tool}" -l <"./${input3}")"
doh_end="$(date "+%s")"
doh_duration="$(((doh_end - doh_start2) / 60))m $(((doh_end - doh_start2) % 60))s"
printf "%s\n" "::: Second run, duration: ${doh_duration}, processed domains: ${cnt}, error domains: ${error_cnt}"

# sanity re-check
#
if [ ! -s "./ipv4.tmp" ] || [ ! -s "./ipv6.tmp" ] || [ ! -s "./domains.tmp" ] || [ ! -f "./domains_abandoned.tmp" ]; then
	printf "%s\n" "ERR: general re-check failed"
	exit 1
fi

# final sort/merge step
#
sort -b -u -n -t. -k1,1 -k2,2 -k3,3 -k4,4 "./ipv4_cache.tmp" "./ipv4.tmp" >"./doh-ipv4.txt"
sort -b -u -k1,1 "./ipv6_cache.tmp" "./ipv6.tmp" >"./doh-ipv6.txt"
sort -b -u "./domains.tmp" >"./doh-domains.txt"
sort -b -u "./domains_abandoned.tmp" >"./doh-domains_abandoned.txt"

cnt_cache_tmpv4="$("${wc_tool}" -l <"./ipv4_cache.tmp")"
cnt_cache_tmpv6="$("${wc_tool}" -l <"./ipv6_cache.tmp")"
cnt_tmpv4="$("${wc_tool}" -l <"./ipv4.tmp")"
cnt_tmpv6="$("${wc_tool}" -l <"./ipv6.tmp")"
cnt_ipv4="$("${wc_tool}" -l <"./doh-ipv4.txt")"
cnt_ipv6="$("${wc_tool}" -l <"./doh-ipv6.txt")"
cnt_domains="$("${wc_tool}" -l <"./doh-domains.txt")"
cnt_domains_abandoned="$("${wc_tool}" -l <"./doh-domains_abandoned.txt")"
doh_end="$(date "+%s")"
doh_duration="$(((doh_end - doh_start1) / 60))m $(((doh_end - doh_start1) % 60))s"

printf "\n::: DOH-processing finished\n"
printf "    Duration: %s\n" "${doh_duration}"
printf "    Cache IPv4/IPv6: %s/%s\n" "${cnt_cache_tmpv4}" "${cnt_cache_tmpv6}"
printf "    All/Unique IPv4: %s/%s\n" "${cnt_tmpv4}" "${cnt_ipv4}"
printf "    All/Unique IPv6: %s/%s\n" "${cnt_tmpv6}" "${cnt_ipv6}"
printf "    Unique domains: %s\n" "${cnt_domains}"
printf "    Abandoned domains: %s\n" "${cnt_domains_abandoned}"
