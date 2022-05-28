#!/bin/sh
# doh-lookup - retrieve IPv4/IPv6 addresses via nslookup from given domain & resolver list
# and write the adjusted output to separate lists (IPv4/IPv6 addresses plus domains)
# Copyright (c) 2019-2022 Dirk Brenken (dev@brenken.org)
#
# This is free software, licensed under the GNU General Public License v3.
#

# prepare environment
#
export LC_ALL=C
: >./ipv4.tmp
: >./ipv6.tmp
: >./domains.tmp
: >./domains_abandoned.tmp
input="./doh-domains_overall.txt"

# set the dns utility, 'host' or 'nslookup'
#
dns_tool="host"
dns_tool="$(command -v ${dns_tool})"

# set upstream dns server
#
upstream="1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222"

# domain per resolver processing
#
while IFS= read -r domain; do
	domain_ok="false"
	for resolver in ${upstream}; do
		out="$(
			"${dns_tool}" "${domain}" "${resolver}" 2>/dev/null
			printf "%s" "${?}"
		)"
		if [ "$(printf "%s" "${out}" | tail -1)" = "0" ]; then
			if [ "${dns_tool##*/}" = "host" ]; then
				ips="$(printf "%s" "${out}" | awk '{if ($0 ~ "has address|has IPv6 address"){ORS=" ";print $NF}}')"
			elif [ "${dns_tool##*/}" = "nslookup" ]; then
				ips="$(printf "%s" "${out}" | awk '/^Address[ 0-9]*: /{ORS=" ";print $NF}')"
			fi
			if [ -n "${ips}" ]; then
				printf "%-40s%-22s%s\n" "OK : ${domain}" "DNS: ${resolver}" "IP: ${ips}"
				for ip in ${ips}; do
					if [ "${ip}" = "0.0.0.0" ] || [ "${ip}" = "::" ]; then
						continue
					else
						domain_ok="true"
						if [ -n "$(printf "%s" "${ip}" | awk '/^(([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?)([[:space:]]|$)/{print $1}')" ]; then
							printf "%-20s%s\n" "${ip}" "# ${domain}" >>./ipv4.tmp
						else
							printf "%-40s%s\n" "${ip}" "# ${domain}" >>./ipv6.tmp
						fi
					fi
				done
			else
				out="$(printf "%s" "${out}" | grep -o "connection timed out\|SERVFAIL\|NXDOMAIN")"
				printf "%-40s%-22s%s\n" "ERR: ${domain}" "DNS: ${resolver}" "RC: ${out:-"unknown"}"
			fi
		else
			out="$(printf "%s" "${out}" | grep -o "connection timed out\|SERVFAIL\|NXDOMAIN")"
			printf "%-40s%-22s%s\n" "ERR: ${domain}" "DNS: ${resolver}" "RC: ${out:-"unknown"}"
		fi
	done
	if [ "${domain_ok}" = "false" ]; then
		printf "%s\n" "${domain}" >>./domains_abandoned.tmp
	else
		printf "%s\n" "${domain}" >>./domains.tmp
	fi
done <"${input}"

# final sort/merge step
#
sort -b -u -n -t. -k1,1 -k2,2 -k3,3 -k4,4 ./ipv4.tmp >./doh-ipv4.txt
sort -b -u -k1,1 ./ipv6.tmp >./doh-ipv6.txt
sort -b -u ./domains.tmp >./doh-domains.txt
sort -b -u ./domains_abandoned.tmp >./doh-domains_abandoned.txt
rm ./ipv4.tmp ./ipv6.tmp ./domains.tmp ./domains_abandoned.tmp
