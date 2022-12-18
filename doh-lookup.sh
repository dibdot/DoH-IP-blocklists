#!/bin/sh
# doh-lookup - retrieve IPv4/IPv6 addresses via dig from a given domain list
# and write the adjusted output to separate lists (IPv4/IPv6 addresses plus domains)
# Copyright (c) 2019-2022 Dirk Brenken (dev@brenken.org)
#
# This is free software, licensed under the GNU General Public License v3.

# disable (s)hellcheck in release
# shellcheck disable=all

# prepare environment
#
export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
input="./doh-domains_overall.txt"
upstream="1.1.1.1 8.8.8.8 77.88.8.88 223.5.5.5"
check_domains="google.com heise.de openwrt.org"
wc_tool="$(command -v wc)"
dig_tool="$(command -v dig)"
awk_tool="$(command -v awk)"
: >"./ipv4.tmp"
: >"./ipv6.tmp"
: >"./domains.tmp"
: >"./domains_abandoned.tmp"

# sanity pre-checks
#
if [ ! -x "${wc_tool}" ] || [ ! -x "${dig_tool}" ] || [ ! -x "${awk_tool}" ] || [ ! -s "${input}" ] || [ -z "${upstream}" ]; then
	printf "%s\n" "ERR: general pre-check failed"
	exit 1
fi

for domain in ${check_domains}; do
	for resolver in ${upstream}; do
		out="$("${dig_tool}" "@${resolver}" "${domain}" A "${domain}" AAAA +noall +answer 2>/dev/null)"
		if [ -z "${out}" ]; then
			printf "%s\n" "ERR: domain pre-check failed"
			exit 1
		else
			ips="$(printf "%s" "${out}" | "${awk_tool}" '/^.*[[:space:]]+IN[[:space:]]+A{1,4}[[:space:]]+/{ORS=" ";print $NF}')"
			if [ -z "${ips}" ]; then
				printf "%s\n" "ERR: ip pre-check failed"
				exit 1
			fi
		fi
	done
done

# domain per resolver processing
#
cnt=0
while IFS= read -r domain; do
	(
		domain_ok="false"
		for resolver in ${upstream}; do
			out="$("${dig_tool}" "@${resolver}" "${domain}" A "${domain}" AAAA +noall +answer 2>/dev/null)"
			if [ -n "${out}" ]; then
				ips="$(printf "%s" "${out}" | "${awk_tool}" '/^.*[[:space:]]+IN[[:space:]]+A{1,4}[[:space:]]+/{ORS=" ";print $NF}')"
				if [ -n "${ips}" ]; then
					printf "%-45s%-22s%s\n" "OK : ${domain}" "DNS: ${resolver}" "IP: ${ips}"
					for ip in ${ips}; do
						if [ "${ip%%.*}" = "0" ] || [ "${ip}" = "::" ] || [ "${ip}" = "1.1.1.1" ] || [ "${ip}" = "8.8.8.8" ]; then
							continue
						else
							domain_ok="true"
							if [ -n "$(printf "%s" "${ip}" | "${awk_tool}" '/^(([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?)([[:space:]]|$)/{print $1}')" ]; then
								printf "%-20s%s\n" "${ip}" "# ${domain}" >>./ipv4.tmp
							else
								printf "%-40s%s\n" "${ip}" "# ${domain}" >>./ipv6.tmp
							fi
						fi
					done
				else
					out="$(printf "%s" "${out}" | grep -m1 -o "timed out\|SERVFAIL\|NXDOMAIN" 2>/dev/null)"
					printf "%-45s%-22s%s\n" "ERR: ${domain}" "DNS: ${resolver}" "RC: ${out:-"unknown"}"
				fi
			else
				printf "%-45s%-22s%s\n" "ERR: ${domain}" "DNS: ${resolver}" "RC: empty output"
			fi
		done
		if [ "${domain_ok}" = "false" ]; then
			printf "%s\n" "${domain}" >>./domains_abandoned.tmp
		else
			printf "%s\n" "${domain}" >>./domains.tmp
		fi
	) &
	hold=$((cnt % 100))
	[ "${hold}" = "0" ] && wait
	cnt=$((cnt + 1))
done <"${input}"
wait

# sanity re-checks
#
if [ ! -s "./ipv4.tmp" ] || [ ! -s "./ipv6.tmp" ] || [ ! -s "./domains.tmp" ] || [ ! -f "./domains_abandoned.tmp" ]; then
	printf "%s\n" "ERR: general re-check failed"
	exit 1
fi

cnt_bad="$("${wc_tool}" -l "./domains_abandoned.tmp" 2>/dev/null | "${awk_tool}" '{print $1}')"
max_bad="$(($("${wc_tool}" -l "${input}" 2>/dev/null | awk '{print $1}') * 20 / 100))"
if [ "${cnt_bad:-"0"}" -ge "${max_bad:-"0"}" ]; then
	printf "%s\n" "ERR: count re-check failed"
	exit 1
fi

# final sort/merge step
#
sort -b -u -n -t. -k1,1 -k2,2 -k3,3 -k4,4 "./ipv4.tmp" >"./doh-ipv4.txt"
sort -b -u -k1,1 "./ipv6.tmp" >"./doh-ipv6.txt"
sort -b -u "./domains.tmp" >"./doh-domains.txt"
sort -b -u "./domains_abandoned.tmp" >"./doh-domains_abandoned.txt"
rm "./ipv4.tmp" "./ipv6.tmp" "./domains.tmp" "./domains_abandoned.tmp"
