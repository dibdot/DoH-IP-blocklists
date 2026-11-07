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
cache_domains="doh.dns.apple.com doh.dns.apple.com.v.aaplimg.com mask-api.icloud.com mask-h2.icloud.com mask.icloud.com dns.nextdns.io dns.cloudflare.com"
ecs_domains="alidns.com aaplimg.com apple.com icloud.com nextdns.io openbld.net"
ecs_views="8.8.8.8,73.0.0.0/24 8.8.8.8,79.192.0.0/24 8.8.8.8,95.24.0.0/24 8.8.8.8,49.36.0.0/24 8.8.8.8,123.112.0.0/24 8.8.8.8,126.0.0.0/24 8.8.8.8,1.120.0.0/24"
dig_tool="$(command -v dig)"
awk_tool="$(command -v awk)"
srt_tool="$(command -v sort)"
cat_tool="$(command -v cat)"
nc_tool="$(command -v nc)"
: >"./ipv4.tmp"
: >"./ipv6.tmp"
: >"./ipv4_ecs.tmp"
: >"./ipv6_ecs.tmp"
: >"./ipv4_cache.tmp"
: >"./ipv6_cache.tmp"
: >"./domains.tmp"
: >"./domains_abandoned.tmp"
[ -f "./doh-ipv4.txt" ] || : >"./doh-ipv4.txt"
[ -f "./doh-ipv6.txt" ] || : >"./doh-ipv6.txt"

# sanity pre-checks
#
if [ ! -x "${dig_tool}" ] || [ ! -x "${awk_tool}" ] || [ ! -x "${srt_tool}" ] || [ ! -x "${cat_tool}" ] || [ ! -x "${nc_tool}" ] || [ ! -s "${input}" ]; then
	printf "%s\n" "ERR: base pre-processing check failed"
	exit 1
fi

for domain in ${check_domains}; do
	out="$("${dig_tool}" +noall +answer +time=2 +tries=3 "${domain}" A "${domain}" AAAA 2>/dev/null)"
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

# ECS pre-check, keep only views where the resolver really forwards the client subnet
#
ecs_ok=""
for view in ${ecs_views}; do
	out="$("${dig_tool}" +short +time=2 +tries=3 +subnet="${view#*,}" @"${view%%,*}" o-o.myaddr.l.google.com TXT 2>/dev/null)"
	case "${out}" in
	*"edns0-client-subnet ${view#*,}"*)
		ecs_ok="${ecs_ok} ${view}"
		;;
	*)
		printf "%s\n" "::: ECS view ${view} not usable, skipped (response: $(printf "%s" "${out:-none}" | tr '\n' ' '))"
		;;
	esac
done
printf "%s\n" "::: Active ECS views:${ecs_ok:- none}"

# pre-fill cache domains (only reachable IPs or fallback to raw cache entries)
#
printf "%s\n" "::: Start cache pre-filling"
cnt="0"
for domain in ${cache_domains}; do

	# IPv4 cache check
	#
	: >"./ipv4_cache_${domain}.tmp"
	"${awk_tool}" -v dom="${domain}" '$0~dom{print $1}' "./doh-ipv4.txt" >"./cache_ips.tmp"
	while read -r ip; do
		[ -z "${ip}" ] && continue
		(
			if "${nc_tool}" -4 -w 3 -z "${ip}" 443 >/dev/null 2>&1; then
				printf "%-20s# %s\n" "${ip}" "${domain}" >>"./ipv4_cache_${domain}.tmp"
			fi
		) &
		cnt="$((cnt + 1))"
		hold="$((cnt % 50))"
		[ "${hold}" = "0" ] && wait
	done <"./cache_ips.tmp"
	wait
	if [ ! -s "./ipv4_cache_${domain}.tmp" ]; then
		printf "%s\n" "::: IPv4: no reachable IPs for ${domain} in cache, fallback to raw cache entries"
		"${awk_tool}" -v dom="${domain}" '$0~dom{print $1}' "./doh-ipv4.txt" |
			while read -r ip; do
				[ -z "${ip}" ] && continue
				printf "%-20s# %s\n" "${ip}" "${domain}" >>"./ipv4_cache_${domain}.tmp"
			done
	fi

	# IPv6 cache check
	#
	: >"./ipv6_cache_${domain}.tmp"
	"${awk_tool}" -v dom="${domain}" '$0~dom{print $1}' "./doh-ipv6.txt" >"./cache_ips.tmp"
	while read -r ip; do
		[ -z "${ip}" ] && continue
		(
			if "${nc_tool}" -6 -w 3 -z "${ip}" 443 >/dev/null 2>&1; then
				printf "%-40s# %s\n" "${ip}" "${domain}" >>"./ipv6_cache_${domain}.tmp"
			fi
		) &
		cnt="$((cnt + 1))"
		hold="$((cnt % 50))"
		[ "${hold}" = "0" ] && wait
	done <"./cache_ips.tmp"
	wait
	if [ ! -s "./ipv6_cache_${domain}.tmp" ]; then
		printf "%s\n" "::: IPv6: no reachable IPs for ${domain} in cache, fallback to raw cache entries"
		"${awk_tool}" -v dom="${domain}" '$0~dom{print $1}' "./doh-ipv6.txt" |
			while read -r ip; do
				[ -z "${ip}" ] && continue
				printf "%-40s# %s\n" "${ip}" "${domain}" >>"./ipv6_cache_${domain}.tmp"
			done
	fi
done
"${cat_tool}" ipv4_cache_*.tmp >ipv4_cache.tmp
"${cat_tool}" ipv6_cache_*.tmp >ipv6_cache.tmp

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
		out="$("${dig_tool}" +noall +answer +time=2 +tries=3 "${domain}" A "${domain}" AAAA 2>/dev/null)"
		if [ -n "${out}" ]; then
			ecs_out=""
			ecs_list=""
			for sfx in ${ecs_domains}; do
				case "${domain}" in
				"${sfx}" | *."${sfx}")
					ecs_list="${ecs_ok}"
					break
					;;
				esac
			done
			for view in ${ecs_list}; do
				ecs_out="${ecs_out}
$("${dig_tool}" +noall +answer +time=2 +tries=2 +subnet="${view#*,}" @"${view%%,*}" "${domain}" A "${domain}" AAAA 2>/dev/null)"
			done
			ips="$(printf "%s\n#ECS#\n%s\n" "${out}" "${ecs_out}" | "${awk_tool}" '$0=="#ECS#"{ecs=1;next}($4=="A"||$4=="AAAA")&&!seen[$5]++{printf "%s%s ",(ecs?"e:":""),$5}')"
			if [ -n "${ips}" ]; then
				for ip in ${ips}; do
					sfx=""
					if [ "${ip#e:}" != "${ip}" ]; then
						ip="${ip#e:}"
						sfx="_ecs"
					fi
					case "$(ipcalc-ng -s --addrspace "${ip}" 2>/dev/null)" in
					"ADDRSPACE=Internet" | 'ADDRSPACE="Global Unicast"') ;;

					*)
						continue
						;;
					esac
					domain_ok="true"
					if [ "${ip##*:}" = "${ip}" ]; then
						printf "%-20s%s\n" "${ip}" "# ${domain}" >>"./ipv4${sfx}.tmp"
					else
						printf "%-40s%s\n" "${ip}" "# ${domain}" >>"./ipv6${sfx}.tmp"
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
	cnt="$((cnt + 1))"
	hold1="$((cnt % 512))"
	hold2="$((cnt % 1024))"
	[ "${hold1}" = "0" ] && sleep 3
	[ "${hold2}" = "0" ] && wait
done <"${input}"
wait

# post-processing checks
#
if [ ! -s "./ipv4.tmp" ] || [ ! -s "./ipv6.tmp" ] || [ ! -s "./domains.tmp" ] || [ ! -f "./domains_abandoned.tmp" ]; then
	printf "%s\n" "ERR: empty output files in post-processing check"
	exit 1
fi
dom_cnt="$("${awk_tool}" 'END{printf "%d",NR}' "./domains.tmp" 2>/dev/null)"
if [ "${dom_cnt}" -lt "$((doh_cnt / 2))" ]; then
	printf "%s\n" "ERR: too many failed domains in post-processing check"
	exit 1
fi

# final sort/merge step (IPv4 + IPv6 with domain aggregation)
# IPv4
#
"${srt_tool}" -b -n -t. -k1,1 -k2,2 -k3,3 -k4,4 "./ipv4_cache.tmp" "./ipv4.tmp" "./ipv4_ecs.tmp" >"./doh-ipv4.raw"
"${awk_tool}" '
{
	match($0, /^([0-9\.]+)[[:space:]]+/, m)
	ip=m[1]
	match($0, /#[[:space:]]*(.*)$/, m2)
	domain=m2[1]
	gsub(/^ +| +$/, "", domain)
	if (domain != "" && !seen[ip,domain]++) {
		map[ip] = (map[ip] ? map[ip] ", " domain : domain)
	}
}
END {
	for (ip in map)
		printf "%-20s# %s\n", ip, map[ip]
}
' "./doh-ipv4.raw" | "${srt_tool}" -t. -k1,1n -k2,2n -k3,3n -k4,4n >"./doh-ipv4.txt"

# IPv6
#
"${srt_tool}" -b -k1,1 "./ipv6_cache.tmp" "./ipv6.tmp" "./ipv6_ecs.tmp" >"./doh-ipv6.raw"
"${awk_tool}" '
{
	match($0, /^([0-9a-fA-F:]+)[[:space:]]+/, m)
	ip=m[1]
	match($0, /#[[:space:]]*(.*)$/, m2)
	domain=m2[1]
	gsub(/^ +| +$/, "", domain)
	if (domain != "" && !seen[ip,domain]++) {
		map[ip] = (map[ip] ? map[ip] ", " domain : domain)
	}
}
END {
	for (ip in map)
		printf "%-40s# %s\n", ip, map[ip]
}
' "./doh-ipv6.raw" | "${srt_tool}" -k1,1 >"./doh-ipv6.txt"
"${srt_tool}" -b -u "./domains.tmp" >"./doh-domains.txt"
"${srt_tool}" -b -u "./domains_abandoned.tmp" >"./doh-domains_abandoned.txt"

# prepare additional json output
#
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-ipv4.txt >./doh-ipv4.json
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-ipv6.txt >./doh-ipv6.json
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-domains.txt >./doh-domains.json
"${awk_tool}" 'BEGIN{print "["} {printf "%s\"%s\"", (NR>1?",\n":""), $1} END{print "\n]"}' ./doh-domains_abandoned.txt >./doh-domains_abandoned.json

# final stats output
#
cnt_cache_tmpv4="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv4_cache.tmp" 2>/dev/null)"
cnt_cache_tmpv6="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv6_cache.tmp" 2>/dev/null)"
cnt_tmpv4="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv4_cache.tmp" "./ipv4.tmp" "./ipv4_ecs.tmp" 2>/dev/null)"
cnt_tmpv6="$("${awk_tool}" 'END{printf "%d",NR}' "./ipv6_cache.tmp" "./ipv6.tmp" "./ipv6_ecs.tmp" 2>/dev/null)"
cnt_ecsv4="$("${awk_tool}" 'FILENAME!="./ipv4_ecs.tmp"{b[$1];next}!($1 in b)&&!s[$1]++{c++}END{printf "%d",c}' "./ipv4_cache.tmp" "./ipv4.tmp" "./ipv4_ecs.tmp" 2>/dev/null)"
cnt_ecsv6="$("${awk_tool}" 'FILENAME!="./ipv6_ecs.tmp"{b[$1];next}!($1 in b)&&!s[$1]++{c++}END{printf "%d",c}' "./ipv6_cache.tmp" "./ipv6.tmp" "./ipv6_ecs.tmp" 2>/dev/null)"
cnt_ipv4="$("${awk_tool}" 'END{printf "%d",NR}' "./doh-ipv4.txt" 2>/dev/null)"
cnt_ipv6="$("${awk_tool}" 'END{printf "%d",NR}' "./doh-ipv6.txt" 2>/dev/null)"
doh_end="$(date "+%s")"
doh_duration="$(((doh_end - doh_start) / 60))m $(((doh_end - doh_start) % 60))s"
printf "%s\n" "::: Finished DOH-processing, duration: ${doh_duration}, cachev4/cachev6: ${cnt_cache_tmpv4}/${cnt_cache_tmpv6}, all/unique IPv4: ${cnt_tmpv4}/${cnt_ipv4}, all/unique IPv6: ${cnt_tmpv6}/${cnt_ipv6}, ECS-only IPv4/IPv6: ${cnt_ecsv4}/${cnt_ecsv6}"
