#!/usr/bin/env bash
# Process doh-ipv4.txt and generate rules file for Little Snitch.

# This is free software, licensed under the GNU General Public License v3.

input="./doh-ipv4.txt"
output="./doh-ipv4-littlesnitch.json"

header="DoH-IP-blocklists
=======================================

IPv4 addresses of public DoH providers.

Updated: $(date -u +"%Y-%m-%d %H:%M:%S (UTC)")

======================================="

header_oneline="${header//$'\n'/\\n}"
export header_oneline


awk -f littlesnitch.awk "${input}" >"${output}"


