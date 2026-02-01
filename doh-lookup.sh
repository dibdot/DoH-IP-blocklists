#!/bin/sh
# doh-lookup - retrieve IPv4/IPv6 addresses via dig from a given domain list
# and write the adjusted output to separate lists (IPv4/IPv6 addresses plus domains)
# Copyright (c) 2019-2026 Dirk Brenken (dev@brenken.org)
#
# This is free software, licensed under the GNU General Public License v3.

# disable (s)hellcheck in release
# shellcheck disable=all

# prepare environment
#
export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
input="./doh-domains_overall.txt"
check_domains="google.com heise.de openwrt.org"
cache_domains="doh.dns.apple.com doh.dns.apple.com.v.aaplimg.com mask-api.icloud.com mask-h2.icloud.com mask.icloud.com dns.nextdns.io"
dig_tool="$(command -v dig)"
awk_tool="$(command -v awk)"
srt_tool="$(command -v sort)"
: >"./ipv4.tmp"
: >"./ipv6.tmp"
: >"./ipv4_cache.tmp"
: >"./ipv6_cache.tmp"
: >"./domains.tmp"
: >"./domains_abandoned.tmp"

# sanity pre-checks
#
if [ ! -x "${dig_tool}" ] || [ ! -x "${awk_tool}" ] || [ ! -s "${input}" ]; then
	printf "%s\n" "ERR: base pre-processing check failed"
	exit 1
fi

for domain in ${check_domains}; do
	out="$("${dig_tool}" +noall +answer +time=1 +tries=2 "${domain}" A "${domain}" AAAA 2>/dev/null)"
	if [ -z "${out}" ]; then
		printf "%s\n" "ERR: domain pre-processing check failed"
		exit 1
	else
		ips="$(printf "%s" "${out}" | "${awk_tool}" '{printf "%s ",$NF}')"
		if [ -z "${ips}" ]; then
			printf "%s\n" "ERR: ip pre-processing check failed"
			exit 1
		fi
	fi
done

# pre-fill cache domains
#
for domain in ${cache_domains}; do
	"${awk_tool}" -v d="${domain}" '$0~d{print $0}' "./doh-ipv4.txt" >>"./ipv4_cache.tmp"
	"${awk_tool}" -v d="${domain}" '$0~d{print $0}' "./doh-ipv6.txt" >>"./ipv6_cache.tmp"
done

# domain processing
#
cnt="0"
doh_start="$(date "+%s")"
doh_cnt="$("${awk_tool}" 'END{printf "%d",NR}' "./${input}" 2>/dev/null)"
printf "%s\n" "::: Start DOH-processing, overall domains: ${doh_cnt}"
while IFS= read -r domain; do
	[ -z "${domain}" ] && continue
	(
		domain_ok="false"
		out="$("${dig_tool}" +noall +answer +time=1 +tries=2 "${domain}" A "${domain}" AAAA 2>/dev/null)"
		if [ -n "${out}" ]; then
			ips="$(printf "%s" "${out}" | "${awk_tool}" '{printf "%s ",$NF}')"
			if [ -n "${ips}" ]; then
				for ip in ${ips}; do
					case "${ip}" in
						10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.*|0.*)
							continue
							;;
						fc*|fd*|fe80:*|::1)
							continue
							;;
					esac
					if ipcalc-ng -s --addrspace "${ip}" | grep -qv "Private"; then
						domain_ok="true"
						if [ "${ip##*:}" = "${ip}" ]; then
							printf "%-20s%s\n" "${ip}" "# ${domain}" >>"./ipv4.tmp"
						else
							printf "%-40s%s\n" "${ip}" "# ${domain}" >>"./ipv6.tmp"
						fi
					fi
				done
			fi
		fi
		if [ "${domain_ok}" = "true" ]; then
			printf "%s\n" "${domain}" >>./domains.tmp
		else
			printf "%s\n" "${domain}" >>./domains_abandoned.tmp
		fi
	) &
	hold1="$((cnt % 512))"
	hold2="$((cnt % 2048))"
	[ "${hold1}" = "0" ] && sleep 3
	[ "${hold2}" = "0" ] && wait
	cnt="$((cnt + 1))"
done <"${input}"
wait

# post-processing check
#
if [ ! -s "./ipv4.tmp" ] || [ ! -s "./ipv6.tmp" ] || [ ! -s "./domains.tmp" ] || [ ! -f "./domains_abandoned.tmp" ]; then
	printf "%s\n" "ERR: post-processing check failed"
	exit 1
fi

# final sort/merge step (IPv4 + IPv6 with domain aggregation)
#
"${srt_tool}" -b -n -t. -k1,1 -k2,2 -k3,3 -k4,4 "./ipv4_cache.tmp" "./ipv4.tmp" > "./doh-ipv4.raw"
"${awk_tool}" '
{
	match($0, /^([0-9\.]+)[[:space:]]+/, m)
	ip=m[1]
	match($0, /#[[:space:]]*(.*)$/, m2)
	domain=m2[1]
	gsub(/^ +| +$/, "", domain)
	if (domain != "")
		map[ip] = (map[ip] ? map[ip] ", " domain : domain)
}
END {
	for (ip in map)
		printf "%-20s# %s\n", ip, map[ip]
}
' "./doh-ipv4.raw" | "${srt_tool}" -t. -k1,1n -k2,2n -k3,3n -k4,4n > "./doh-ipv4.txt"

"${srt_tool}" -b -k1,1 "./ipv6_cache.tmp" "./ipv6.tmp" > "./doh-ipv6.raw"
"${awk_tool}" '
{
	match($0, /^([0-9a-fA-F:]+)[[:space:]]+/, m)
	ip=m[1]
	match($0, /#[[:space:]]*(.*)$/, m2)
	domain=m2[1]
	gsub(/^ +| +$/, "", domain)
	if (domain != "")
		map[ip] = (map[ip] ? map[ip] ", " domain : domain)
}
END {
	for (ip in map)
		printf "%-40s# %s\n", ip, map[ip]
}
' "./doh-ipv6.raw" | "${srt_tool}" -k1,1 > "./doh-ipv6.txt"
"${srt_tool}" -b -u "./domains.tmp" > "./doh-domains.txt"
"${srt_tool}" -b -u "./domains_abandoned.tmp" > "./doh-domains_abandoned.txt"

# prepare additional json output
#
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-ipv4.txt > ./doh-ipv4.json
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-ipv6.txt > ./doh-ipv6.json
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-domains.txt > ./doh-domains.json
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-domains_abandoned.txt > ./doh-domains_abandoned.json

# final stats output
#
cnt_cache_tmpv4="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv4_cache.tmp" 2>/dev/null)"
cnt_cache_tmpv6="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv6_cache.tmp" 2>/dev/null)"
cnt_tmpv4="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv4.tmp" 2>/dev/null)"
cnt_tmpv6="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv6.tmp" 2>/dev/null)"
cnt_ipv4="$("${awk_tool}" 'END{printf "%d",NR}' "./doh-ipv4.txt" 2>/dev/null)"
cnt_ipv6="$("${awk_tool}" 'END{printf "%d",NR}' "./doh-ipv6.txt" 2>/dev/null)"
doh_end="$(date "+%s")"
doh_duration="$(((doh_end - doh_start) / 60))m $(((doh_end - doh_start) % 60))s"
printf "%s\n" "::: Finished DOH-processing, duration: ${doh_duration}, cachev4/cachev6: ${cnt_cache_tmpv4}/${cnt_cache_tmpv6}, all/unique IPv4: ${cnt_tmpv4}/${cnt_ipv4}, all/unique IPv6: ${cnt_tmpv6}/${cnt_ipv6}"
