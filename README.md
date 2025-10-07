# DoH-IP-blocklists

This repo contains the domain names and the IPv4/IPv6 addresses of public DoH server.  
The main domain list `doh-domains_overall.txt` is manually updated on a regular basis (usually once a month). All other output files in this repo are derived from that file and generated automatically with the help of the script `doh-lookup.sh`:  
  * `doh-domains[.txt|.json]`: active or accessible domains  
  * `doh-domains_abandoned[.txt|.json]`: unavailable domains  
  * `doh-ipv4[.txt|.json]`: list with the ipv4 addresses of the accessible domains  
  * `doh-ipv6[.txt|.json]`: list with the ipv6 addresses of the accessible domains  

The doh-lookup script runs automatically every hour via GitHub actions and updates the above listed output files within the repo if anything has changed.  

Have fun!  
Dirk Brenken  
